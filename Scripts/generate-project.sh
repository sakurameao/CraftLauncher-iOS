#!/usr/bin/env bash
#
# generate-project.sh
#
# Turns project.yml into CraftLauncher.xcodeproj via XcodeGen.
#
# The project file is generated rather than committed on purpose: a hand-written
# .pbxproj is unreviewable and merges badly, while these ~140 lines of YAML say the
# same thing in a form a human can read and a reviewer can diff.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

cd "${PROJECT_ROOT}"

# ── XcodeGen ──────────────────────────────────────────────────────────────────

step "检查 XcodeGen"

if ! command -v xcodegen >/dev/null 2>&1; then
  fail "没有找到 xcodegen。"
  note "安装方式：brew install xcodegen"
  exit 1
fi
ok "$(xcodegen --version 2>&1 | head -1)"

# ── Runtime payload ───────────────────────────────────────────────────────────

step "检查 Java 运行时"

runtime_missing=0

if [[ ! -d "Runtime/Frameworks" ]] || [[ -z "$(ls -A Runtime/Frameworks 2>/dev/null)" ]]; then
  warn "Runtime/Frameworks 是空的"
  runtime_missing=1
else
  ok "Frameworks 中有 $(find Runtime/Frameworks -name '*.dylib' | wc -l | tr -d ' ') 个库"
fi

if [[ ! -d "Runtime/libs" ]] || [[ -z "$(ls -A Runtime/libs 2>/dev/null)" ]]; then
  warn "Runtime/libs 是空的"
  runtime_missing=1
else
  ok "libs 中有 $(find Runtime/libs -name '*.jar' | wc -l | tr -d ' ') 个 jar"
fi

# The Java runtimes are complete directory trees, not archives. Both are needed:
# Java 8 for 1.16.5 and older, Java 17 for 1.17 - 1.20.4.
for jre in java-8-openjdk java-17-openjdk; do
  if [[ ! -d "Runtime/java_runtimes/${jre}" ]]; then
    warn "缺少运行时 Runtime/java_runtimes/${jre}"
    runtime_missing=1
  else
    version="$(grep -m1 '^JAVA_VERSION=' "Runtime/java_runtimes/${jre}/release" 2>/dev/null | cut -d'"' -f2 || echo '?')"
    ok "${jre}  (Java ${version})"
  fi
done

if (( runtime_missing == 1 )); then
  printf '\n'
  warn "工程仍然会生成，但构建出来的 App 无法启动游戏。"
  note "请先运行：./Scripts/bootstrap-runtime.sh"
  printf '\n'
fi

# ── Generate ──────────────────────────────────────────────────────────────────

step "生成 Xcode 工程"
xcodegen generate --spec project.yml --project .
ok "CraftLauncher.xcodeproj"

# ── Report ────────────────────────────────────────────────────────────────────

printf '\n'
note "打开工程：open CraftLauncher.xcodeproj"
note "记得在 Signing & Capabilities 里选择你的开发者团队。"
printf '\n'
