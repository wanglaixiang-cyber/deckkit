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
#  默认编译仓库里那份并（原来在跑就）重启它 —— 平时就用源码版。
#  想装到 /Applications（常驻、加进登录项）就显式 `deck menu --install`，
#  之后要回到源码版：`deck menu --dev`（会停掉 /Applications 那份再起仓库这份）。
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
    --dev)     DEV_ONLY=1 ;;      # 显式「就用源码版」：默认就是这个，写出来更清楚
  esac
done
if [ "${DEV_ONLY}" = 1 ] && [ "${INSTALL}" = 1 ]; then
  die "--dev 和 --install 不能一起用"
fi

# 记下编译前是否在跑：在跑的话编完自动拉起来，
# 免得「改了代码只编译不重启」把菜单栏图标弄没了（踩过）。
WAS_RUNNING=0
pgrep -x "${EXE}" >/dev/null 2>&1 && WAS_RUNNING=1

echo "… 停掉正在运行的旧版本"
pkill -x "${EXE}" 2>/dev/null || true
# 等它真的没了再往下：固定 sleep 1 之后 `open` 有可能只是**激活还活着的那份旧
# 进程**（新编出来的那份根本没起来，改动看着没生效）。最多等 5 秒。
i=0
while pgrep -x "${EXE}" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
  sleep 0.25; i=$((i + 1))
done
if pgrep -x "${EXE}" >/dev/null 2>&1; then
  echo "${YLW}! 旧进程还在（可能卡住了），强杀${RST}"
  pkill -9 -x "${EXE}" 2>/dev/null || true
  sleep 0.5
fi

echo "… 准备 App 包结构"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

# ── 图标：用代码画（仓库里不放二进制素材），缓存成 AppIcon.icns ──
ICNS="${HERE}/AppIcon.icns"
if command -v iconutil >/dev/null 2>&1; then
  if [ ! -f "$ICNS" ] || [ "${HERE}/makeicon.swift" -nt "$ICNS" ]; then
    echo "… 生成图标（makeicon.swift → AppIcon.icns）"
    TMPI="$(mktemp -d)"
    # stderr 收进变量：失败时原样打出来（以前 2>/dev/null 只剩一句猜的
    # 「swift 解释器？」，等于把真原因扔了）
    if ICON_ERR="$(swift "${HERE}/makeicon.swift" "$TMPI" 2>&1 >/dev/null)"; then
      mkdir -p "${TMPI}/AppIcon.iconset"
      for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
                  "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
                  "512 512x512" "1024 512x512@2x"; do
        # read 而不是 set -- $spec：set -- 会覆写整个脚本的位置参数
        #（现在还无害，但以后别处要用 "$@" 就会莫名拿到这里的东西）
        read -r sz name <<EOF
$spec
EOF
        sips -z "$sz" "$sz" "${TMPI}/master.png" --out "${TMPI}/AppIcon.iconset/icon_${name}.png" >/dev/null 2>&1
      done
      if iconutil -c icns "${TMPI}/AppIcon.iconset" -o "$ICNS" 2>/dev/null; then
        ok "图标已生成"
      else
        echo "${YLW}! 打 icns 失败，这次不带图标${RST}"
      fi
    else
      echo "${YLW}! 画图标失败，这次不带图标 —— 原始报错：${RST}"
      printf '%s\n' "${ICON_ERR:-（没有输出）}" | sed 's/^/    /' | head -5
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
# -target 必须写：不写的话产物的 minos 跟着**构建机**走（实测 otool 出来是
# minos 27.0），而 Info.plist 声明的是 11.0 —— 于是「支持 macOS 11+」是假的，
# 在比构建机老的系统上直接起不来。Arch 从 uname -m 取（arm64 / x86_64）。
ARCH="$(uname -m)"
swiftc -O -swift-version 5 \
  -target "${ARCH}-apple-macos11.0" \
  -framework Cocoa \
  -o "${APP}/Contents/MacOS/${EXE}" \
  "${HERE}/main.swift" \
  || die "编译失败"

sign_app() {   # 图标/plist 都放好之后才签，否则签名会失效
  codesign --force --sign - "$1" 2>/dev/null
}

# 冒烟自检：编译通过 ≠ 起得来（缺符号、plist 写坏、swift 版本不兼容都是编得过
# 但一启动就崩）。--dump 是只读自检（它不跑 ensure），拿它当门禁。
echo "… 冒烟自检（--dump）"
if ! DUMP_OUT="$("${APP}/Contents/MacOS/${EXE}" --dump 2>&1)"; then
  printf '%s\n' "$DUMP_OUT" | head -5 | sed 's/^/    /'
  die "编出来的 App 跑不起来（--dump 非 0 退出）"
fi
case "$DUMP_OUT" in
  *"Steam Deck"*) ok "自检通过（菜单能正常生成）" ;;
  *) echo "${YLW}! --dump 的输出里没有 'Steam Deck'，菜单可能不正常：${RST}"
     printf '%s\n' "$DUMP_OUT" | head -5 | sed 's/^/    /' ;;
esac

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

  # ── 开机自启：写一个 LaunchAgent ──
  # 为什么不用「系统设置 → 登录项」那条老路：**macOS 13 起没有了**。
  # `osascript ... make login item` 在 macOS 27 上直接不工作（实测：登录项列表里
  # 怎么都加不进去），所以 App 重启后就不会回来 —— 用户看到的现象就是
  # 「重启了，服务又没了」。LaunchAgent 是现在唯一可靠、可脚本化的做法。
  #
  # 用 `open -a` 而不是直接跑可执行文件：走 LaunchServices 才有正确的 bundle 身份
  # （图标、Dock 策略、LSUIElement、本地网络权限都按 com.example.deckkit.menubar
  # 这条身份走）。直接 exec Bundle 里的二进制会丢掉这些。
  agent_plist="${HOME}/Library/LaunchAgents/com.example.deckkit.menubar.plist"
  mkdir -p "$(dirname "${agent_plist}")"
  cat > "${agent_plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.example.deckkit.menubar</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>${APP_INSTALLED}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <!-- 不设 KeepAlive：菜单里本来就有「退出 deckkit」，硬拉起会跟用户意图打架。
       这里只保证「登录时起一次」。 -->
</dict>
</plist>
PLIST
  # 重新加载（先卸旧的，忽略"没加载过"的报错）
  launchctl bootout "gui/$(id -u)/com.example.deckkit.menubar" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "${agent_plist}" 2>/dev/null \
     || launchctl load -w "${agent_plist}" 2>/dev/null; then
    ok "已设置开机自启（LaunchAgent）"
  else
    echo "${YLW}! LaunchAgent 注册失败 —— 手动加："
    echo "   cp '${agent_plist}' ~/Library/LaunchAgents/ && launchctl load -w '${agent_plist}'${RST}"
  fi
fi

# 启动/重启哪一个：只有这次真的 --install 了才起 /Applications 那份，
# 否则一律起仓库里这份（源码版）—— 两份同时跑会出现两个菜单栏图标。
TARGET="${APP}"
# 注意写成 if：`[ … ] && TARGET=…` 在 INSTALL=0 时整条为假，set -e 会直接把脚本干掉（实测）
if [ "${INSTALL}" = 1 ]; then
  TARGET="${APP_INSTALLED}"
fi
echo "启动：open '${TARGET}'"


if [ "${RUN}" = 1 ] || [ "${WAS_RUNNING}" = 1 ] || [ "${INSTALL}" = 1 ]; then
  open "${TARGET}"
  ok "已启动 ${TARGET}（看菜单栏右上角）"
  if [ "${INSTALL}" = 1 ]; then
    echo "${YLW}! 首次从 /Applications 启动时，macOS 可能会重新问一次「本地网络」权限${RST}"
    echo "   系统设置 → 隐私与安全性 → 本地网络 → 允许 deckkit"
  fi
fi
