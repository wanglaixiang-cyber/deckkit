#!/usr/bin/env bash
# ============================================================
#  deckkit —— 编译菜单栏 App
#
#    ./build.sh           编译（产物：本目录下的 DeckKit.app）
#    ./build.sh --run     编译完顺便启动
#
#  产物是一个 LSUIElement（无 Dock 图标）的小 App，双击即可常驻菜单栏，
#  也可以在「系统设置 → 通用 → 登录项」里加进开机自启。
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
APP="${HERE}/DeckKit.app"
EXE="DeckKit"
BUNDLE_ID="com.example.deckkit.menubar"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()  { echo "${GRN}✓${RST} $*"; }
die() { echo "${RED}✗${RST} $*" >&2; exit 1; }

command -v swiftc >/dev/null 2>&1 || die "找不到 swiftc。装一下 Xcode 命令行工具：xcode-select --install"

RUN=0
[ "${1:-}" = "--run" ] && RUN=1

# 记下编译前是否在跑：在跑的话编完自动拉起来，
# 免得「改了代码只编译不重启」把菜单栏图标弄没了（踩过）。
WAS_RUNNING=0
pgrep -x "${EXE}" >/dev/null 2>&1 && WAS_RUNNING=1

echo "… 停掉正在运行的旧版本"
pkill -x "${EXE}" 2>/dev/null || true
sleep 1

echo "… 准备 App 包结构"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

echo "… 写 Info.plist"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>deckkit</string>
    <key>CFBundleDisplayName</key><string>deckkit</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${EXE}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <!-- 只驻留菜单栏，不进 Dock、不抢焦点 -->
    <key>LSUIElement</key><true/>
    <!-- macOS 15+ 的「本地网络」权限：没有这个说明，系统可能不给弹授权提示。
         这个 App 需要它，因为「由它启动的 next dev」才连得到 Deck 上的后端
         （终端启动的 node 拿不到该权限）。 -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>deckkit 需要访问局域网才能连到 Steam Deck（服务状态、前端 API、NFS 挂载）。</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <!-- 框架根目录，供 App 找 services/ 与 bin/deck -->
    <key>DeckkitRoot</key><string>${ROOT}</string>
</dict>
</plist>
PLIST

echo "… 编译 Swift"
swiftc -O -swift-version 5 \
  -framework Cocoa \
  -o "${APP}/Contents/MacOS/${EXE}" \
  "${HERE}/main.swift" \
  || die "编译失败"

echo "… 临时签名"
codesign --force --sign - "${APP}" 2>/dev/null && ok "已签名" \
  || echo "${YLW}! 签名跳过（不影响本机使用）${RST}"

ok "编译完成：${APP}"
echo "   框架根目录：${ROOT}"
echo
echo "启动：open '${APP}'"
echo "开机自启：系统设置 → 通用 → 登录项 → 添加 DeckKit.app"

if [ "${RUN}" = 1 ]; then
  open "${APP}"
  ok "已启动，看菜单栏右上角"
elif [ "${WAS_RUNNING}" = 1 ]; then
  open "${APP}"
  ok "原来就在跑，已自动重新启动"
fi
