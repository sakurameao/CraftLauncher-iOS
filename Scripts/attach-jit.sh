#!/usr/bin/env bash
#
# attach-jit.sh
#
# Grants JIT to a running CraftLauncher by attaching a debugger, which is the only
# supported way to do it on an unjailbroken device.
#
#     ./Scripts/attach-jit.sh              # auto-detect device, launch, then attach
#     ./Scripts/attach-jit.sh --attach     # attach to an already-running app
#
# On iOS 17.0.1 and later the debug server can no longer be reached directly, so
# this drives `pymobiledevice3` through a tunnelled connection. If it fails, see
# docs/JIT.md for the TrollStore and SideStore alternatives, which are much less
# fragile.

set -euo pipefail

BUNDLE_ID="com.craftlauncher.ios"
MODE="launch"

for arg in "$@"; do
  case "${arg}" in
    --attach) MODE="attach" ;;
    --help|-h)
      sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

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

[[ "$(uname -s)" == "Darwin" ]] || { fail "只能在 macOS 上运行。"; exit 1; }

# ── Tooling ───────────────────────────────────────────────────────────────────

step "检查工具"

have_pymobiledevice3=0
if command -v pymobiledevice3 >/dev/null 2>&1; then
  have_pymobiledevice3=1
  ok "pymobiledevice3 $(pymobiledevice3 version 2>/dev/null || echo '')"
else
  warn "没有找到 pymobiledevice3"
  note "安装：pip3 install -U pymobiledevice3"
  note "或者改用 TrollStore / SideStore，见 docs/JIT.md"
fi

have_xcrun=0
if xcrun devicectl --version >/dev/null 2>&1; then
  have_xcrun=1
  ok "devicectl 可用"
fi

# ── Device ────────────────────────────────────────────────────────────────────

step "查找设备"

DEVICE_UDID=""

if [[ -n "${CRAFTLAUNCHER_UDID:-}" ]]; then
  DEVICE_UDID="${CRAFTLAUNCHER_UDID}"
  ok "使用环境变量指定的设备：${DEVICE_UDID}"
elif [[ ${have_pymobiledevice3} -eq 1 ]]; then
  DEVICE_UDID="$(pymobiledevice3 usbmux list 2>/dev/null \
    | python3 -c 'import json,sys
try:
    devices = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in devices:
    udid = d.get("Identifier") or d.get("UniqueDeviceID")
    if udid:
        print(udid)
        break' 2>/dev/null || true)"
fi

if [[ -z "${DEVICE_UDID}" ]]; then
  fail "没有找到已连接的 iOS 设备。"
  note "请用数据线连接设备，并在设备上点「信任此电脑」。"
  note "也可以直接指定：CRAFTLAUNCHER_UDID=<udid> $0"
  exit 1
fi
ok "设备 ${DEVICE_UDID}"

# ── Attach ────────────────────────────────────────────────────────────────────

if [[ ${have_pymobiledevice3} -eq 0 ]]; then
  fail "缺少 pymobiledevice3，无法继续。"
  note "pip3 install -U pymobiledevice3"
  exit 1
fi

step "建立隧道"

# iOS 17.0.1+ requires a userspace tunnel before the debug server is reachable.
# It runs in the background for the lifetime of this script.
TUNNEL_LOG="$(mktemp -t craftlauncher-tunnel)"

cleanup() {
  if [[ -n "${TUNNEL_PID:-}" ]] && kill -0 "${TUNNEL_PID}" 2>/dev/null; then
    kill "${TUNNEL_PID}" 2>/dev/null || true
  fi
  rm -f "${TUNNEL_LOG}"
}
trap cleanup EXIT

pymobiledevice3 lockdown start-tunnel --udid "${DEVICE_UDID}" > "${TUNNEL_LOG}" 2>&1 &
TUNNEL_PID=$!

# Wait for the tunnel to report ready rather than sleeping a fixed amount.
tunnel_ready=0
for _ in $(seq 1 30); do
  if grep -qiE 'RSD|tunnel.*(started|ready)|Address' "${TUNNEL_LOG}" 2>/dev/null; then
    tunnel_ready=1
    break
  fi
  if ! kill -0 "${TUNNEL_PID}" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

if [[ ${tunnel_ready} -eq 1 ]]; then
  ok "隧道已建立"
  grep -iE 'RSD|Address' "${TUNNEL_LOG}" | head -3 | while read -r line; do note "${line}"; done
else
  warn "隧道可能没有建立成功，仍然尝试继续"
  note "隧道输出：$(tail -3 "${TUNNEL_LOG}" 2>/dev/null | tr '\n' ' ')"
fi

if [[ "${MODE}" == "launch" ]]; then
  step "启动 CraftLauncher"
  # `--wait-for-debugger` is the useful part: the app blocks at startup until a
  # debugger connects, which removes the race between launching and attaching.
  if xcrun devicectl device process launch \
        --device "${DEVICE_UDID}" \
        --wait-for-debugger \
        "${BUNDLE_ID}" >/dev/null 2>&1; then
    ok "已请求启动（等待调试器）"
  else
    warn "无法通过 devicectl 启动，请在设备上手动打开 CraftLauncher"
    note "然后在 5 秒内回到这里继续"
    sleep 5
  fi
fi

step "开启 JIT"

if pymobiledevice3 developer dvt enable-jit \
      --udid "${DEVICE_UDID}" \
      --pid "$(pymobiledevice3 developer dvt proclist --udid "${DEVICE_UDID}" 2>/dev/null \
                | grep -i craftlauncher | head -1 | awk '{print $1}')" 2>&1; then
  ok "JIT 已开启"
else
  fail "开启 JIT 失败"
  printf '\n'
  note "可能的原因和替代方案："
  note "  1. 设备没有信任这台电脑 —— 重新插拔并在设备上确认"
  note "  2. 设备锁屏 —— 解锁后重试"
  note "  3. 系统版本不支持这种方式 —— 见 docs/JIT.md 里的 TrollStore / SideStore 方案"
  printf '\n'
  exit 1
fi

printf '\n'
note "回到设备上的 CraftLauncher，到「设置 → 运行环境」确认 JIT 显示「已启用」。"
note "注意：设备每次重启后都要重新执行一次这个脚本。"
printf '\n'
