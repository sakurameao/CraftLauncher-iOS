#!/usr/bin/env bash
#
# bootstrap-runtime.sh
#
# Populates ./Runtime/ with the prebuilt iOS Java runtimes and graphics libraries
# that CraftLauncher loads at launch.
#
# Everything here is compiled for arm64-apple-ios and cannot be built from this
# repository, so it is extracted from the upstream PojavLauncher release.
#
#     ./Scripts/bootstrap-runtime.sh                  # download and extract
#     ./Scripts/bootstrap-runtime.sh --ipa FILE.ipa   # use a local copy
#     ./Scripts/bootstrap-runtime.sh --force          # re-extract
#
# Afterwards:
#
#     Runtime/java_runtimes/java-8-openjdk/    Java 8  (Minecraft <= 1.16.5)
#     Runtime/java_runtimes/java-17-openjdk/   Java 17 (1.17 - 1.20.4)
#     Runtime/Frameworks/                      patched dylibs
#     Runtime/libs/                            patched jars + Caciocavallo
#     Runtime/log4j-rce-patch-*.xml            Log4Shell patches
#
# The upstream release is GPL-3.0; see docs/ARCHITECTURE.md for attribution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Pinned so a rebuild reproduces the same runtime.
POJAV_REPO="PojavLauncherTeam/PojavLauncher_iOS"
POJAV_VERSION="2.2"
# Note the spelling: the *release asset* is `pojavlaunch**er**-...`, while the Java
# package is `net.kdt.pojavlaunch.PojavLauncher` (no "er"). Mixing the two produces
# a 404 that looks exactly like a network block, which is how this script spent a
# while chasing a CDN that was never the problem.
POJAV_IPA_NAME="net.kdt.pojavlauncher-${POJAV_VERSION}-ios.ipa"
# Verified against the release API; also proves a download is the real file and not
# a truncated one.
POJAV_IPA_BYTES=108175347

# Optional. The asset is public, so a token is not required — but supplying one
# raises the GitHub API rate limit, which matters if the fallback path is used
# repeatedly, and GitHub Actions provides one automatically.
GITHUB_TOKEN_VALUE="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# ── Output helpers ────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  BOLD=''; GREEN=''; YELLOW=''; RED=''; DIM=''; RESET=''
fi

step() { printf '%s==>%s %s\n' "${BOLD}" "${RESET}" "$1"; }
ok()   { printf '%s  ✓%s %s\n' "${GREEN}" "${RESET}" "$1"; }
warn() { printf '%s  !%s %s\n' "${YELLOW}" "${RESET}" "$1"; }
fail() { printf '%s  ✗%s %s\n' "${RED}" "${RESET}" "$1" >&2; }
note() { printf '%s    %s%s\n' "${DIM}" "$1" "${RESET}"; }

# Portable file size. `stat` flags differ between BSD and GNU, so avoid it.
file_size() { wc -c < "$1" | tr -d '[:space:]'; }

# ── Arguments ─────────────────────────────────────────────────────────────────

LOCAL_IPA=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipa)   LOCAL_IPA="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --help|-h)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) fail "未知参数：$1"; exit 2 ;;
  esac
done

# ── Locate an extractor ───────────────────────────────────────────────────────
#
# Deliberately not macOS-only. The runtime binaries are prebuilt, so extracting
# them is a plain zip operation any platform can do — which means this script runs
# on the Windows development machine too, not just on a Mac.

EXTRACTOR=""
if command -v bsdtar >/dev/null 2>&1; then
  EXTRACTOR="bsdtar"
elif command -v ditto >/dev/null 2>&1; then
  EXTRACTOR="ditto"
elif command -v unzip >/dev/null 2>&1; then
  EXTRACTOR="unzip"
elif [[ -x "/c/Windows/System32/tar.exe" ]]; then
  EXTRACTOR="wintar"
fi

if [[ -z "${EXTRACTOR}" ]]; then
  fail "找不到解压工具（需要 bsdtar、ditto、unzip 或 Windows 自带的 tar）。"
  exit 1
fi
note "解压工具：${EXTRACTOR}"

WORK_DIR="${PROJECT_ROOT}/.bootstrap"
mkdir -p "${WORK_DIR}"

# ── Obtain the IPA ────────────────────────────────────────────────────────────

IPA_PATH=""
CANDIDATE="${WORK_DIR}/pojavlauncher.ipa"

if [[ -n "${LOCAL_IPA}" ]]; then
  if [[ ! -f "${LOCAL_IPA}" ]]; then
    fail "指定的 IPA 不存在：${LOCAL_IPA}"
    exit 1
  fi
  IPA_PATH="${LOCAL_IPA}"
  ok "使用本地 IPA：${IPA_PATH}"
elif [[ -f "${CANDIDATE}" ]] && [[ "$(file_size "${CANDIDATE}")" == "${POJAV_IPA_BYTES}" ]]; then
  # The 103 MB download only needs to happen once.
  IPA_PATH="${CANDIDATE}"
  ok "复用已下载的 IPA（删除它可强制重新下载）"
else
  step "下载 PojavLauncher ${POJAV_VERSION}（约 103 MB）"

  BROWSER_URL="https://github.com/${POJAV_REPO}/releases/download/v${POJAV_VERSION}/${POJAV_IPA_NAME}"

  if ! command -v curl >/dev/null 2>&1; then
    fail "需要 curl 来下载。请手动下载后用 --ipa 指定："
    note "  ${BROWSER_URL}"
    exit 1
  fi

  # Resume only makes sense when a partial file is already present. `-C -` with no
  # local file sends `Range: bytes=1-`, which some endpoints answer with an error.
  RESUME_FLAG=""
  if [[ -s "${CANDIDATE}" ]]; then
    RESUME_FLAG="-C -"
    note "发现部分文件（$(file_size "${CANDIDATE}") 字节），尝试续传"
  fi

  # A `once` helper, because the same curl invocation is tried against two URLs.
  download_ipa() {
    curl --fail --location --progress-bar \
         --retry 5 --retry-delay 2 --retry-all-errors \
         ${RESUME_FLAG} --output "${CANDIDATE}" "$1"
  }

  step "下载 IPA"
  if ! download_ipa "${BROWSER_URL}"; then
    # Fallback: resolve the asset through the API and fetch it by id.
    #
    # The primary path — the plain `releases/download/...` URL — is the simple one
    # and is what normally runs. This fallback exists because that URL redirects to
    # `objects.githubusercontent.com`, which has been seen to fail on some routes,
    # and because the API endpoint serves the bytes directly and supports ranges.
    #
    # Node is used for the JSON, not shell parsing. An earlier attempt used
    # `tr ',' '\n'` + `grep -n` + `sed`, which breaks on any string containing a
    # comma and whose failures look identical to a network problem — that ambiguity
    # cost real debugging time on a bug that was actually a misspelled filename.
    warn "直连 releases/download 失败，改走 API 资产端点"
    rm -f "${CANDIDATE}"

    if command -v node >/dev/null 2>&1; then
      export POJAV_REPO POJAV_VERSION POJAV_IPA_NAME
      ASSET_URL="$(node -e '
        const headers = {
          "User-Agent": "CraftLauncher",
          Accept: "application/vnd.github+json",
        };
        if (process.env.GITHUB_TOKEN) {
          headers.Authorization = "Bearer " + process.env.GITHUB_TOKEN;
        }
        const url =
          "https://api.github.com/repos/" + process.env.POJAV_REPO +
          "/releases/tags/v" + process.env.POJAV_VERSION;
        fetch(url, { headers, signal: AbortSignal.timeout(30000) })
          .then((r) => (r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status))))
          .then((release) => {
            const asset = (release.assets || []).find(
              (a) => a.name === process.env.POJAV_IPA_NAME
            );
            if (!asset) {
              console.error(
                "资产不存在。release 里有: " +
                (release.assets || []).map((a) => a.name).join(", ")
              );
              process.exit(1);
            }
            process.stdout.write(asset.url);
          })
          .catch((e) => {
            console.error(e.message);
            process.exit(1);
          });
      ' 2>/dev/null || true)"
    fi

    if [[ -n "${ASSET_URL}" ]]; then
      ok "资产端点：${ASSET_URL}"
      DOWNLOAD_HEADERS=(-H "Accept: application/octet-stream")
      if [[ -n "${GITHUB_TOKEN_VALUE}" ]]; then
        DOWNLOAD_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN_VALUE}")
      fi

      if ! curl --fail --location --progress-bar \
                --retry 5 --retry-delay 2 --retry-all-errors \
                "${DOWNLOAD_HEADERS[@]}" \
                ${RESUME_FLAG} --output "${CANDIDATE}" "${ASSET_URL}"; then
        fail "两条下载路径都失败了。"
        note "手动下载 ${POJAV_IPA_NAME} 后用 --ipa 指定："
        note "  ./Scripts/bootstrap-runtime.sh --ipa /path/to/${POJAV_IPA_NAME}"
        exit 1
      fi
    else
      fail "下载失败，且无法通过 API 解析资产。"
      note "请检查文件名是否拼错（注意是 pojavlaunch${BOLD}er${RESET}）："
      note "  ${BROWSER_URL}"
      note "也可以手动下载后用 --ipa 指定。"
      exit 1
    fi
  fi

  IPA_PATH="${CANDIDATE}"
fi

IPA_SIZE="$(file_size "${IPA_PATH}")"
if [[ "${IPA_SIZE}" != "${POJAV_IPA_BYTES}" ]]; then
  warn "IPA 大小是 ${IPA_SIZE} 字节，预期 ${POJAV_IPA_BYTES}。"
  note "文件被截断或版本不对都会这样。如果后续提取失败，删掉它重新下载。"
else
  ok "IPA 完整（${IPA_SIZE} 字节）"
fi

# ── Extract ───────────────────────────────────────────────────────────────────

EXTRACT_DIR="${WORK_DIR}/extracted"

if [[ ${FORCE} -eq 1 ]] || [[ ! -d "${EXTRACT_DIR}/Payload" ]]; then
  step "解包 IPA"
  rm -rf "${EXTRACT_DIR}"
  mkdir -p "${EXTRACT_DIR}"
  case "${EXTRACTOR}" in
    bsdtar) bsdtar -xf "${IPA_PATH}" -C "${EXTRACT_DIR}" ;;
    wintar) "/c/Windows/System32/tar.exe" -xf "${IPA_PATH}" -C "${EXTRACT_DIR}" ;;
    *)      unzip -q -o "${IPA_PATH}" -d "${EXTRACT_DIR}" ;;
  esac
  ok "解包完成"
else
  ok "复用已解包的内容（--force 可强制重新解包）"
fi

APP_BUNDLE="$(find "${EXTRACT_DIR}/Payload" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
if [[ -z "${APP_BUNDLE}" ]] || [[ ! -d "${APP_BUNDLE}" ]]; then
  fail "在 IPA 里找不到 .app 包。"
  note "解包可能不完整。删掉 ${EXTRACT_DIR} 后重试，或用 --force。"
  exit 1
fi
ok "找到 $(basename "${APP_BUNDLE}")"

RUNTIME_DIR="${PROJECT_ROOT}/Runtime"
mkdir -p "${RUNTIME_DIR}"

# ── 1. Java runtimes ──────────────────────────────────────────────────────────
#
# The upstream ships these as complete directory trees, NOT as zip archives. They
# are trimmed runtimes: no `bin/` directory at all, only `lib/`. The JVM is started
# by dlopen-ing libjli.dylib and calling JLI_Launch, which is why no `bin/java`
# executable is needed.

step "提取 Java 运行时"

SOURCE_RUNTIMES="${APP_BUNDLE}/java_runtimes"
TARGET_RUNTIMES="${RUNTIME_DIR}/java_runtimes"

if [[ ! -d "${SOURCE_RUNTIMES}" ]]; then
  fail "运行时里没有 java_runtimes 目录，IPA 结构可能变了。"
  exit 1
fi

rm -rf "${TARGET_RUNTIMES}"
mkdir -p "${TARGET_RUNTIMES}"

found_runtimes=()
while IFS= read -r -d '' jre; do
  name="$(basename "${jre}")"
  cp -R "${jre}" "${TARGET_RUNTIMES}/"
  found_runtimes+=("${name}")

  # Read the version from the runtime's own `release` file rather than trusting
  # the directory name.
  version="$(grep -m1 '^JAVA_VERSION=' "${jre}/release" 2>/dev/null | cut -d'"' -f2 || echo '?')"
  arch="$(grep -m1 '^OS_ARCH=' "${jre}/release" 2>/dev/null | cut -d'"' -f2 || echo '?')"
  ok "${name}  (Java ${version}, ${arch})"
done < <(find "${SOURCE_RUNTIMES}" -mindepth 1 -maxdepth 1 -type d -print0)

if (( ${#found_runtimes[@]} == 0 )); then
  fail "java_runtimes 里没有找到任何运行时。"
  exit 1
fi

# The app selects a runtime by matching these directory names. Warn loudly if
# upstream renames one, because the failure would otherwise be a bare
# "找不到 Java 17" with no obvious cause.
for expected in java-8-openjdk java-17-openjdk; do
  if [[ ! -d "${TARGET_RUNTIMES}/${expected}" ]]; then
    warn "缺少 ${expected} —— 需要它的游戏版本会提示找不到运行时。"
    note "上游目前提供的：${found_runtimes[*]}"
  fi
done

# ── 2. Frameworks ─────────────────────────────────────────────────────────────

step "提取 Frameworks（图形库与 AWT 支持）"

SOURCE_FRAMEWORKS="${APP_BUNDLE}/Frameworks"
TARGET_FRAMEWORKS="${RUNTIME_DIR}/Frameworks"

if [[ ! -d "${SOURCE_FRAMEWORKS}" ]]; then
  fail "运行时里没有 Frameworks 目录。"
  exit 1
fi

rm -rf "${TARGET_FRAMEWORKS}"
mkdir -p "${TARGET_FRAMEWORKS}"

# Graphics and JNI libraries only. The launcher UI frameworks (Alderis, AltKit,
# CAltKit, libAFNetworking) belong to the upstream app and CraftLauncher does not
# use them — bundling them would just add weight.
copied=0
while IFS= read -r -d '' item; do
  name="$(basename "${item}")"
  skip=0
  for pattern in Alderis AltKit CAltKit libAFNetworking; do
    [[ "${name}" == *"${pattern}"* ]] && skip=1
  done
  [[ ${skip} -eq 1 ]] && continue

  cp -R "${item}" "${TARGET_FRAMEWORKS}/"
  copied=$((copied + 1))
done < <(find "${SOURCE_FRAMEWORKS}" -mindepth 1 -maxdepth 1 -print0)

ok "复制了 ${copied} 个条目"

# These are what the launcher probes for at startup; a missing entry produces a
# clear message instead of an opaque dlopen failure.
missing_libs=()
for required in libawt_xawt.dylib libMoltenVK.dylib libgl4es_114.dylib libOSMesa.8.dylib; do
  [[ -e "${TARGET_FRAMEWORKS}/${required}" ]] || missing_libs+=("${required}")
done
if (( ${#missing_libs[@]} > 0 )); then
  warn "缺少预期中的库：${missing_libs[*]}"
  note "上游可能改了打包方式。检查 ${SOURCE_FRAMEWORKS}"
else
  ok "关键图形库齐全"
fi

# ── 3. Jars ───────────────────────────────────────────────────────────────────
#
# Three sources, all of which must land in the app's single `libs/` directory
# because that is what `-cp <libs>/*` points at:
#
#   libs/                  patched LWJGL (lwjgl3-minecraft.jar is the merged one),
#                          the Java-side launcher, gson, jsr305
#   libs_caciocavallo/     AWT toolkit for Java 8
#   libs_caciocavallo17/   AWT toolkit for Java 17 — different package names, so
#                          both must be present or one Java generation breaks

step "提取 jar（LWJGL 补丁与 Caciocavallo）"

TARGET_LIBS="${RUNTIME_DIR}/libs"
rm -rf "${TARGET_LIBS}"
mkdir -p "${TARGET_LIBS}"

jar_count=0
for source_sub in libs libs_caciocavallo libs_caciocavallo17; do
  source_dir="${APP_BUNDLE}/${source_sub}"
  if [[ ! -d "${source_dir}" ]]; then
    warn "运行时里没有 ${source_sub} 目录"
    continue
  fi
  count=0
  while IFS= read -r -d '' jar; do
    cp -f "${jar}" "${TARGET_LIBS}/"
    count=$((count + 1))
  done < <(find "${source_dir}" -maxdepth 1 -type f -name '*.jar' -print0)
  ok "${source_sub}/  ${count} 个 jar"
  jar_count=$((jar_count + count))
done

if (( jar_count == 0 )); then
  fail "一个 jar 都没提取到，游戏无法启动。"
  exit 1
fi

# The Java-side entry point. Without it the JVM starts and immediately reports
# "Could not find or load main class net.kdt.pojavlaunch.PojavLauncher".
if [[ -f "${TARGET_LIBS}/launcher.jar" ]]; then
  ok "launcher.jar 已就位"
else
  warn "libs/ 里没有 launcher.jar —— Java 侧入口类缺失，游戏无法启动。"
fi

# ── 4. Log4Shell patches ──────────────────────────────────────────────────────

step "提取 log4j 安全补丁"

patch_count=0
for patch in log4j-rce-patch-1.7.xml log4j-rce-patch-1.12.xml; do
  if [[ -f "${APP_BUNDLE}/${patch}" ]]; then
    cp -f "${APP_BUNDLE}/${patch}" "${RUNTIME_DIR}/"
    patch_count=$((patch_count + 1))
  fi
done
if (( patch_count > 0 )); then
  ok "复制了 ${patch_count} 个 log4j 补丁配置"
else
  warn "没有找到 log4j 补丁配置，1.7 / 1.12 将使用服务端下发的配置。"
fi

# ── 5. Upstream licence ───────────────────────────────────────────────────────

for candidate in "LICENSE" "LICENSE.txt" "Payload/LICENSE"; do
  if [[ -f "${EXTRACT_DIR}/${candidate}" ]]; then
    cp -f "${EXTRACT_DIR}/${candidate}" "${RUNTIME_DIR}/UPSTREAM-LICENSE"
    ok "已保存上游许可证"
    break
  fi
done

# ── Report ────────────────────────────────────────────────────────────────────

step "完成"
printf '\n'
note "运行时目录：${RUNTIME_DIR}"
note "总体积：$(du -sh "${RUNTIME_DIR}" 2>/dev/null | cut -f1 || echo '?')"
printf '\n'
note "这个目录会被打包进 App，所以最终 .ipa 有 300-400 MB —— 这是正常的，"
note "体积来自两个完整的 OpenJDK。"
printf '\n'
note "下一步：./Scripts/generate-project.sh"
printf '\n'
