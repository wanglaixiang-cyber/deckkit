#!/usr/bin/env bash
# ============================================================
#  deckkit —— 编译菜单栏 App
#
#    ./build.sh             编译（产物：本目录下的 DeckKit.app）
#    ./build.sh --run       编译完顺便启动
#    ./build.sh --install   编译 + 装到 /Applications/DeckKit.app，并启动那份
#    ./build.sh --dev       只想编仓库里这份、别碰 /Applications（装了之后默认会装）
#
#  产物是一个 LSUIElement（无 Dock 图标）的小 App：双击常驻菜单栏，
#  也可以在「系统设置 → 通用 → 登录项」里加进开机自启。
#
#  装到 /Applications 之后，**那份才是正主**：本脚本默认改成「编译 + 重新安装 +
#  重启 /Applications 那份」（只编不装会让你以为改了没生效）。要只编仓库里这份，
#  用 --dev。App 靠 Info.plist 里的 DeckkitRoot 找仓库（services/、bin/deck），
#  所以仓库别删、别随便挪 —— 挪了要重新 --install。
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
APP="${HERE}/DeckKit.app"
APP_INSTALLED="/Applications/DeckKit.app"
EXE="DeckKit"
BUNDLE_ID="com.example.deckkit.menubar"

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()  { echo "${GRN}✓${RST} $*"; }
die() { echo "${RED}✗${RST} $*" >&2; exit 1; }

command -v swiftc >/dev/null 2>&1 || die "找不到 swiftc。装一下 Xcode 命令行工具：xcode-select --install"

RUN=0; INSTALL=0; DEV_ONLY=0
for a in "$@"; do
  case "$a" in
    --run)     RUN=1 ;;
    --install) INSTALL=1 ;;
    --dev)     DEV_ONLY=1 ;;
  esac
done
# 装了 /Applications 那份之后，默认就一直维护它（不然改完代码只编仓库这份，
# 跑着的还是旧 App —— 菜单栏没变化，白折腾）
if [ "${DEV_ONLY}" != 1 ] && [ -d "$APP_INSTALLED" ]; then
  INSTALL=1
fi

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

# ── 图标：用代码画（仓库里不放二进制素材），缓存成 AppIcon.icns ──
ICNS="${HERE}/AppIcon.icns"
if command -v iconutil >/dev/null 2>&1; then
  if [ ! -f "$ICNS" ] || [ "${HERE}/makeicon.swift" -nt "$ICNS" ]; then
    echo "… 生成图标（makeicon.swift → AppIcon.icns）"
    TMPI="$(mktemp -d)"
    if swift "${HERE}/makeicon.swift" "$TMPI" >/dev/null 2>&1; then
      mkdir -p "${TMPI}/AppIcon.iconset"
      for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
                  "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
                  "512 512x512" "1024 512x512@2x"; do
        set -- $spec
        sips -z "$1" "$1" "${TMPI}/master.png" --out "${TMPI}/AppIcon.iconset/icon_$2.png" >/dev/null 2>&1
      done
      if iconutil -c icns "${TMPI}/AppIcon.iconset" -o "$ICNS" 2>/dev/null; then
        ok "图标已生成"
      else
        echo "${YLW}! 打 icns 失败，这次不带图标${RST}"
      fi
    else
      echo "${YLW}! 画图标失败（swift 解释器？），这次不带图标${RST}"
    fi
    rm -rf "$TMPI"
  fi
else
  echo "${YLW}! 没有 iconutil，跳过图标${RST}"
fi
[ -f "$ICNS" ] && cp -f "$ICNS" "${APP}/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <!-- 只驻留菜单栏，不进 Dock、不抢焦点 -->
    <key>LSUIElement</key><true/>
    <!-- macOS 15+ 的「本地网络」权限：没有这个说明，系统可能不给弹授权提示。
         这个 App 需要它：由它启动的 node 才连得到 Deck 上的服务
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

sign_app() {   # 图标/plist 都放好之后才签，否则签名会失效
  codesign --force --sign - "$1" 2>/dev/null
}

echo "… 临时签名"
sign_app "${APP}" && ok "已签名" || echo "${YLW}! 签名跳过（不影响本机使用）${RST}"

ok "编译完成：${APP}"
echo "   框架根目录：${ROOT}（App 靠它找 services/ 与 bin/deck）"

# ── 装到 /Applications ──
if [ "${INSTALL}" = 1 ]; then
  [ -w /Applications ] || die "/Applications 不可写 —— 用管理员账号，或改用 --dev"
  echo "… 安装到 ${APP_INSTALLED}"
  rm -rf "${APP_INSTALLED}"
  # ditto 而不是 cp -R：保留权限与扩展属性（签名才不会白签）
  ditto "${APP}" "${APP_INSTALLED}" || die "拷贝到 /Applications 失败"
  if ! codesign --verify --deep --strict "${APP_INSTALLED}" 2>/dev/null; then
    echo "${YLW}! 安装后的签名校验没过，就地重签一次${RST}"
    sign_app "${APP_INSTALLED}"
  fi
  xattr -dr com.apple.quarantine "${APP_INSTALLED}" 2>/dev/null || true
  ok "已安装：${APP_INSTALLED}"
fi

# 启动/重启哪一个：装了就以 /Applications 那份为准
TARGET="${APP}"
[ -d "${APP_INSTALLED}" ] && TARGET="${APP_INSTALLED}"
echo "启动：open '${TARGET}'"
echo "开机自启：系统设置 → 通用 → 登录项 → 添加 DeckKit.app"

if [ "${RUN}" = 1 ] || [ "${WAS_RUNNING}" = 1 ] || [ "${INSTALL}" = 1 ]; then
  open "${TARGET}"
  ok "已启动 ${TARGET}（看菜单栏右上角）"
  if [ "${INSTALL}" = 1 ]; then
    echo "${YLW}! 首次从 /Applications 启动时，macOS 可能会重新问一次「本地网络」权限${RST}"
    echo "   系统设置 → 隐私与安全性 → 本地网络 → 允许 deckkit"
  fi
fi
