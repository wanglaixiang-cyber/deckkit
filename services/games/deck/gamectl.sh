#!/usr/bin/env bash
# ============================================================
#  deckkit / games —— Deck 侧执行体（在 Deck 上跑）
#
#    gamectl.sh protons                      可用的 Proton
#    gamectl.sh prefix <appid>               建/查这个 appid 的 prefix
#    gamectl.sh run <appid> <exe> [--silent] 用该 prefix 跑安装器（DISPLAY 已设）
#    gamectl.sh snapshot <dir>               打印 <rel>\t<size>\t<mtime> 清单
#    gamectl.sh diff <before> <after>        两份清单的差异（装了/改了哪些文件）
#    gamectl.sh find-game-exe <appid>        安装后在 prefix 里挑出游戏主程序
#    gamectl.sh find-game-exe --dir <目录>   在任意目录里挑（免安装游戏拷过来的目录树）
#    gamectl.sh size <path>                  人类可读体积
#    gamectl.sh remove-prefix <appid>        删掉 prefix（不可逆）
#    gamectl.sh steam-running                0 = 在跑，1 = 没跑（写 shortcuts 前要确认）
#    gamectl.sh shortcut-check               shortcuts.vdf 解析/回写是否无损
#    gamectl.sh shortcut-has <appid>         回读确认（按 appid，名字是日文也能查）
#    gamectl.sh shortcut-add <appid> <名字> <linux exe> <起始目录> [图标]
#
#  为什么需要它：Windows 游戏/安装器在 Deck 上要跑在**属于自己的 Proton prefix**
#  里，并且需要显示会话（桌面模式）。这套环境装配 + 安装前后对比，就是本服务干的事。
# ============================================================
set -uo pipefail

GAMES_ROOT="${GAMES_ROOT:-$HOME/deckkit/services/games}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 公共库（由 `deck games install-here` 一起推上来）：颜色/消息、Proton 枚举、
# 快照、桌面会话凭证、日志锚点都在里面 —— patchctl.sh 用的是同一份。
# **库不在也能跑**：退回本文件自带的最小定义（通用件缺失而已，proton 枚举与
# 快照照旧工作）。日志和库都是辅助，不该成为服务的依赖。
_lib="${HOME}/deckkit/bin/deck-lib"
if [ -r "$_lib" ]; then
  # shellcheck source=../../../bin/deck-lib
  . "$_lib"
else
  ok()   { printf '  \xe2\x9c\x93 %s\n' "$*"; }
  warn() { printf '  ! %s\n' "$*"; }
  bad()  { printf '  \xe2\x9c\x97 %s\n' "$*"; }
  die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
  deckkit_protons_dir() { printf '%s/steamapps/common' "$HOME/.steam/steam"; }
  deckkit_protons() {
    local d; for d in "$(deckkit_protons_dir)"/Proton*; do
      [ -d "$d" ] || continue; [ -x "$d/proton" ] && basename "$d"
    done
  }
  deckkit_pick_proton() {
    [ -n "${PROTON:-}" ] && { printf '%s' "$PROTON"; return 0; }
    local p; p="$(deckkit_protons | grep -E '^Proton [0-9]' | sort -t' ' -k2 -V | tail -1)"
    [ -n "$p" ] || p="$(deckkit_protons | grep -i experimental | head -1)"
    [ -n "$p" ] || p="$(deckkit_protons | head -1)"
    [ -n "$p" ] || return 1
    printf '%s' "$p"
  }
  # 兜底版与库里的语义一致：0 = find 跑通；非 0 = 目录不在或有读不了的子树
  deckkit_snapshot() {
    local dir="$1" out rc
    [ -d "$dir" ] || return 1
    out="$(find "$dir" -type f -printf '%P\t%s\t%T@\n' 2>/dev/null)"; rc=$?
    [ -n "$out" ] && printf '%s\n' "$out" | sort
    return "$rc"
  }
  deckkit_display_env() { :; }
  deckkit_require_display() { deckkit_display_env; }
  deckkit_proton_env() {
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.steam/steam"
    export STEAM_COMPAT_DATA_PATH="$1"
    export PROTON_USE_XALIA=0
  }
  deckkit_log_path() { printf '%s/%s.log' "$HOME/deckkit/logs" "$1"; }
  deckkit_log_rotate() { return 0; }
fi

# 日志走统一入口（~/deckkit/bin/deck-log）：位置/格式/滚动定在一处，
# 读的时候 Mac 上 `deck logs games-install` 直接就有。
INSTALL_LOG="$(deckkit_log_path games-install)"
[ -n "$INSTALL_LOG" ] || INSTALL_LOG="$GAMES_ROOT/install.log"
STEAM="$HOME/.steam/steam"
COMPAT="$STEAM/steamapps/compatdata"
PROTONS_DIR="$STEAM/steamapps/common"
PROTON="${PROTON:-}"                        # 留空由 cmd_run 自动挑

# 这两个是 gamectl 对外的子命令名（历史用法，配置文档里也这么写）
cmd_protons() { deckkit_protons; }
pick_proton() { deckkit_pick_proton; }

prefix_dir() { printf '%s' "$COMPAT/$1"; }

cmd_prefix() {
  local id="$1" p; p="$(prefix_dir "$id")"
  mkdir -p "$p"
  printf '%s\n' "$p"
}

cmd_run() {
  local id="$1" exe="$2" silent="${3:-}"
  local p; p="$(prefix_dir "$id")"
  [ -d "$p" ] || mkdir -p "$p"
  [ -f "$exe" ] || die "找不到安装包：$exe"
  local proton; proton="$(deckkit_pick_proton)" || die "Deck 上没找到 Proton"
  # prefix 环境 + 关掉 Xalia + 从桌面会话进程里捞 DISPLAY/XAUTHORITY：
  # 都在库的 deckkit_proton_env / deckkit_require_display 里。
  #（ssh 进来时环境里既没有 DISPLAY 也没有 XAUTHORITY，硬写 :0 会
  #  "Authorization required" —— Wine 开不出窗口、安装器干等，用户实测
  #  Deck 桌面端什么提示都没有；所以先捞、再**预检**，连不上就直接报错。
  #  另外 Proton 会注入 Xalia 这个手柄导航组件，在非 Steam 上下文里必崩
  #  （Unhandled exception in Xalia → 窗口从不出现），PROTON_USE_XALIA=0 关掉它。）
  deckkit_proton_env "$p"
  deckkit_require_display
  printf '  桌面     %s（XAUTHORITY %s）\n' "$DISPLAY" "${XAUTHORITY:-未设置}"
  printf '  Xalia    关闭（PROTON_USE_XALIA=0）\n' 
  printf '  proton   %s\n' "$proton"
  printf '  prefix   %s\n' "$p"
  printf '  DISPLAY  %s\n' "${DISPLAY:-（没有桌面会话）}"
  # 输出重定向到日志文件，**不要**继承 ssh 的管道：proton 退出后 wineserver
  # 之类的子进程还会活一会儿，抓着管道不放会让 ssh 一直不返回（踩过）。
  # 轮转 + 锚点：原来是 `: > "$log"` 直接清空（上次安装的现场就没了），
  # 而现在装完才发现不对时还能回看上一条记录。
  local log="$INSTALL_LOG"
  # 轮转一代再写锚点（库会判断工具在不在）。原来是 `: > "$log"` 直接清空 ——
  # 上次安装的现场就没了；锚点是必须的：proton 的输出不带时间戳。
  deckkit_log_rotate games-install "===== 跑安装器：$(basename "$exe")${silent:+ ${silent}} =====" || true
  local rc=0
  if [ "$silent" = "--silent" ]; then
    "${PROTONS_DIR}/${proton}/proton" run "$exe" /S >>"$log" 2>&1 || rc=$?
  else
    "${PROTONS_DIR}/${proton}/proton" run "$exe" >>"$log" 2>&1 || rc=$?
  fi
  tail -6 "$log" | sed 's/^/    /'
  return $rc
}

# 快照：**退出码是诚实的**（0 = find 真跑通，输出可以是空的；1 = 目录不在/读不了）。
# 老写法 `find … | sort` 的退出码来自 sort（恒为 0）—— 调用方的
# `|| die "快照失败"` 永远不触发，空清单被当成「安装前后一个文件都没变」。
cmd_snapshot() { deckkit_snapshot "$1"; }

# 前后清单差异：新增/改动/删除
cmd_diff() {
  local before="$1" after="$2"
  join -t$'\t' -j1 -o '0,1.2,2.2' <(sort "$before") <(sort "$after") 2>/dev/null | \
  awk -F'\t' '{ if ($2 != $3) print "mod\t" $1 }'
  comm -13 <(cut -f1 "$before" | sort) <(cut -f1 "$after" | sort) | sed 's/^/new\t/'
  comm -23 <(cut -f1 "$before" | sort) <(cut -f1 "$after" | sort) | sed 's/^/del\t/'
}

# 挑主程序时排除的东西：卸载器/安装器/运行库/Steam 自身。
# 注意 `drive_c/Program Files[^/]*/Steam/` **不能**简写成 `/Steam/`：每个 prefix 的
# 路径里都含 ~/.steam/steam/steamapps/…，那样写会把所有 exe 滤光（踩过）。
EXE_EXCLUDE='unins|setup|install|vc_redist|dxsetup|dotnet|crashpad|crashhandler|crashreport|launcher_installer|steamerrorreporter|steam\.exe|drive_c/Program Files[^/]*/Steam/|steamwebhelper|winedevice'

# 在一棵目录树里挑主程序：排除上面那些，取最大的 exe
pick_exe() {   # <根目录> [最大深度]
  local root="$1" depth="${2:-5}"
  [ -d "$root" ] || return 0
  find "$root" -maxdepth "$depth" -type f -iname '*.exe' 2>/dev/null \
    | grep -viE "$EXE_EXCLUDE" \
    | while read -r f; do printf '%s\t%s\n' "$(stat -c%s "$f")" "$f"; done \
    | sort -rn | head -1 | cut -f2
}

# 找游戏主程序：默认在 prefix 的 drive_c 里找（装 exe 的游戏，装完才找得到）；
# `--dir <路径>` 在任意目录里找（免安装游戏：拷过去就已经在那儿了）
cmd_find_game_exe() {
  if [ "${1:-}" = "--dir" ]; then
    shift
    pick_exe "$1" 6
    return 0
  fi
  pick_exe "$(prefix_dir "$1")/pfx/drive_c" 5
}

# 把「装好的应用」变成一个桌面菜单项：名字/图标取自 prefix 里 Proton 生成的
# proton_shortcuts/*.desktop 和 icons/，Exec 指向我们的 run.sh（导好了 prefix+Proton）
cmd_desktop() {
  local slug="$1" name="$2" launcher="$3" appid="$4"
  local ps="$COMPAT/$appid/pfx/drive_c/proton_shortcuts"
  local src="" dname="" icon_src="" icon_dst=""
  [ -d "$ps" ] && {
    src="$(find "$ps" -maxdepth 1 -name '*.desktop' 2>/dev/null | head -1)"
    [ -n "$src" ] && dname="$(sed -n 's/^Name=//p' "$src" | head -1)"
    icon_src="$(find "$ps/icons" -maxdepth 1 -type f 2>/dev/null | head -1)"
  }
  [ -n "$dname" ] || dname="$name"
  local gdir="$HOME/.local/share/deckkit/games/$slug"
  mkdir -p "$gdir"
  if [ -n "$icon_src" ]; then
    icon_dst="$gdir/icon.${icon_src##*.}"
    cp -f "$icon_src" "$icon_dst" 2>/dev/null
  fi
  mkdir -p "$HOME/.local/share/applications"
  local out="$HOME/.local/share/applications/deckkit-$slug.desktop"
  {
    echo '[Desktop Entry]'
    echo 'Type=Application'
    echo "Name=$dname"
    echo 'Comment=deckkit 装的 Windows 应用（Proton）'
    [ -n "$icon_dst" ] && echo "Icon=$icon_dst"
    echo "Exec=$launcher"
    echo 'Terminal=false'
    echo 'Categories=Game;'
  } > "$out"
  chmod +x "$out"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1
  ok "桌面菜单项 ${out}（${dname}）"
}

cmd_size() { du -sh "${1:-/nonexistent}" 2>/dev/null | cut -f1; }

cmd_remove_prefix() {
  local id="$1" p; p="$(prefix_dir "$id")"
  [ -d "$p" ] || die "没有这个 prefix：$p"
  rm -rf "$p" || die "删除失败：$p"
  ok "已删除 prefix $(basename "$p")"
}

cmd_steam_running() { pgrep -x steam >/dev/null 2>&1; }

cmd_shortcut_check() {
  python3 "$SELF_DIR/shortcut-vdf.py" --check "$STEAM/userdata" 2>&1
}

cmd_shortcut_remove() { python3 "$SELF_DIR/shortcut-vdf.py" --remove "$STEAM/userdata" "$1"; }

cmd_shortcut_has() { python3 "$SELF_DIR/shortcut-vdf.py" --has "$STEAM/userdata" "$1"; }

cmd_shortcut_restore() { python3 "$SELF_DIR/shortcut-vdf.py" --restore "$STEAM/userdata"; }

cmd_shortcut_add() {
  python3 "$SELF_DIR/shortcut-vdf.py" --add "$STEAM/userdata" "$@" 2>&1
}

case "${1:-help}" in
  protons)       cmd_protons ;;
  prefix)        shift; cmd_prefix "$@" ;;
  run)           shift; cmd_run "$@" ;;
  snapshot)      shift; cmd_snapshot "$@" ;;
  diff)          shift; cmd_diff "$@" ;;
  find-game-exe) shift; cmd_find_game_exe "$@" ;;
  size)          shift; cmd_size "$@" ;;
  desktop)       shift; cmd_desktop "$@" ;;
  remove-prefix) shift; cmd_remove_prefix "$@" ;;
  steam-running) cmd_steam_running && { echo running; exit 0; } || { echo stopped; exit 1; } ;;
  shortcut-check) cmd_shortcut_check ;;
  shortcut-has)     shift; cmd_shortcut_has "$@" ;;
  shortcut-add)     shift; cmd_shortcut_add "$@" ;;
  shortcut-restore) cmd_shortcut_restore ;;
  shortcut-remove)  shift; cmd_shortcut_remove "$@" ;;
  -h|--help|help|"") sed -n '2,20p' "$0" | sed 's/^# \?//' ;;
  *) die "gamectl 不认识的子命令：$1" ;;
esac
