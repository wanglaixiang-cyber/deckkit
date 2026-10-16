#!/usr/bin/env bash
# ============================================================
#  deckkit games —— 汉化游戏中文缺字修复（Wine / Proton 层）
#
#    winfonts.sh status              看当前状态（Proton 源文件 + 每个 prefix）
#    winfonts.sh install             装（Proton 字体替换 + 每个 prefix 补 family）
#    winfonts.sh install --prefix ID  只给某一个 compatdata 号补 prefix 部分
#    winfonts.sh remove              还原（有备份就还，没备份就报出来）
#
#  一般由 `deck games fonts` 调，不用手跑。
#
#  ── 为什么必须修在这一层（全部是实测结论）──
#   · Proton 自带的 files/share/fonts/msgothic.ttc **不是** MS Gothic，而是
#     Ume-Gothic（14963 字形，只有 JIS）。「头/开/结/戏/环/继/续」一个都没有：
#       $ python3 -c "..." → '从新·始境束游····置·存档'
#     SRPG Studio 系汉化游戏（MyGame/交響曲/協奏曲/終曲、鎮魂歌）把 UI
#     字体写死在 data.dts 项目段里，值就是 "MS Gothic" → 游戏里直接**空白**。
#   · 終曲那款项目段里没写字体，引擎退回写死在 game.exe 里的 "Meiryo UI"；
#     prefix 里没有这个 family → 豆腐块。
#   · Wine 的 SystemLink 兜底链（Tahoma/System/MS Shell Dlg → MSGOTHIC.TTC,MS UI
#     Gothic）指向同一个 Ume-Gothic；链里那条 `MSYH.TTC,Microsoft YaHei UI`
#     因为 Proton 只放了 msyh.ttf（文件名对不上）而**断掉** → 兜底也接不上。
#   · fontconfig 别名（~/.config/fontconfig/fonts.conf）对 Proton 游戏**无效**：
#     实测 Deck 上 `fc-match "MS Gothic"` 已指向 Noto CJK，游戏里照旧缺字 ——
#     Wine 优先命中 prefix 里**按文件名注册**的 msgothic.ttc，不走 fontconfig 匹配。
#     （所以那个 fonts.conf 只对 Linux 原生程序有用，保留它是为了别的场景。）
#
#  ── 做法 ──
#   (1) 用一份覆盖 GB18030 的中文 TTC（~/.local/share/deckkit/fonts/deckkit-sc.ttc，
#       由 mac/mkfont.py 从 Proton 的 msyh.ttf 改名生成）**覆盖 Proton 的
#       msgothic.ttc**（原件备份成 msgothic.ttc.deckkit-orig）。
#       注意：Proton **每次启动**都会把 prefix 里的字体符号链接重建（实测：改完
#       prefix 里的 msgothic.ttc，下次启动就变回 Proton 的），所以只能改**源头**。
#   (2) 往每个 prefix 的 drive_c/windows/Fonts/ 里补 meiryo.ttc / msyh.ttc 符号
#       链接 —— 这两个名字 Proton 不管，能活下来，补上 Meiryo / Meiryo UI /
#       Microsoft YaHei UI 这些 family。
#   (3) md5 记账：Proton 更新把源文件换回去之后 status 一眼能看出来，重跑 install 即可。
#
#  不碰任何游戏文件；只动 Proton 的字体文件和 prefix 的 Fonts 目录，可整体还原。
# ============================================================
set -uo pipefail

GAMES="$HOME/.local/share/deckkit/games"
STORE="$HOME/deckkit/services/games/store"
FONTDIR="$HOME/.local/share/deckkit/fonts"
TTC="$FONTDIR/deckkit-sc.ttc"
STATEDIR="$FONTDIR/state"
STEAM="$HOME/.steam/steam"
MARK="deckkit-sc.ttc"
PREFIX_NAMES="meiryo.ttc msyh.ttc"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# 我们要补进每个 prefix 的字体文件是否就位
need_ttc() { [ -f "$TTC" ] || die "缺少 ${TTC}（先在 Mac 侧跑 deck games fonts）"; }

# deckkit 的游戏用到的 Proton 安装目录（从 run.sh 里抓），并集上所有能修的 Proton
proton_dirs() {
  local rel=""
  for f in "$GAMES"/*/run.sh; do
    [ -f "$f" ] || continue
    rel="$rel$(grep -o 'steamapps/common/Proton[^"]*' "$f" 2>/dev/null | sed 's#/proton$##')
"
  done
  for d in "$STEAM"/steamapps/common/Proton*; do
    [ -d "$d/files/share/fonts" ] && rel="$rel${d#"$STEAM"/}
"
  done
  printf '%s' "$rel" | sed '/^$/d' | sort -u | sed "s#^#$STEAM/#"
}

# deckkit 的游戏用到的 compatdata 号
prefix_ids() {
  {
    for f in "$GAMES"/*/run.sh; do
      [ -f "$f" ] || continue
      grep -o 'compatdata/[0-9]*' "$f" 2>/dev/null | sed 's#compatdata/##'
    done
    for m in "$STORE"/*/meta.tsv; do
      [ -f "$m" ] || continue
      sed -n 's/^appid=//p' "$m"
    done
  } | grep -E '^[0-9]+$' | sort -u
}

# 某个 prefix 的 Windows Fonts 目录（不存在就返回空）
font_dir_of() {
  local d="$STEAM/steamapps/compatdata/$1/pfx/drive_c/windows/Fonts"
  [ -d "$d" ] && printf '%s' "$d"
}

hmd5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ── install：Proton 源文件 ──
patch_proton() {
  local p t n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    t="$p/files/share/fonts/msgothic.ttc"
    [ -f "$t" ] || continue
    if [ "$(hmd5 "$t")" = "$(hmd5 "$TTC")" ]; then
      say "  = 已是 deckkit 字体  ${p##*/}"
      continue
    fi
    [ -f "$t.deckkit-orig" ] || cp -p "$t" "$t.deckkit-orig"
    cp "$TTC" "$t" || die "写不进去：$t"
    n=$((n + 1))
    say "  + 替换 msgothic.ttc  ${p##*/}（原件已备份 .deckkit-orig）"
  done < <(proton_dirs)
  [ "$n" = 0 ] && say "  （Proton 那边已经就位，没动）"
  return 0
}

# ── install：prefix 里补 family ──
patch_prefix() {
  local id="$1" fd n st
  fd="$(font_dir_of "$id")"
  [ -n "$fd" ] || return 1
  mkdir -p "$STATEDIR"
  st="$STATEDIR/$id.tsv"
  for n in $PREFIX_NAMES; do
    # 已经指对了就不动（反复 ln 会把 Fonts 目录 mtime 搅乱，没意义）
    if [ -L "$fd/$n" ] && [ "$(readlink "$fd/$n")" = "$TTC" ]; then continue; fi
    [ -f "$st" ] || : >"$st"
    if ! grep -q "^$n	" "$st" 2>/dev/null; then
      if [ -L "$fd/$n" ]; then
        printf '%s\tlink\t%s\n' "$n" "$(readlink "$fd/$n")" >>"$st"
      elif [ -e "$fd/$n" ]; then
        printf '%s\tfile\t-\n' "$n" >>"$st"
      else
        printf '%s\tabsent\t-\n' "$n" >>"$st"
      fi
    fi
    rm -f "$fd/$n"
    ln -s "$TTC" "$fd/$n" || return 1
  done
  printf '%s' "$id"
}

cmd_status() {
  say "中文字体修复（Wine / Proton 层）"
  if [ -f "$TTC" ]; then
    say "  ✓ 字体文件 ${TTC}（$(hmd5 "$TTC" | cut -c1-12)…）"
  else
    say "  ✗ 没有 $TTC —— 在 Mac 侧跑：deck games fonts"
  fi
  say "  Proton 源文件："
  local p t
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    t="$p/files/share/fonts/msgothic.ttc"
    [ -f "$t" ] || continue
    if [ -f "$TTC" ] && [ "$(hmd5 "$t")" = "$(hmd5 "$TTC")" ]; then
      say "    ✓ ${p##*/}  msgothic.ttc = deckkit 中文字体"
    else
      local bk="（无备份）"
      [ -f "$t.deckkit-orig" ] && bk="（原件在 msgothic.ttc.deckkit-orig）"
      say "    ✗ ${p##*/}  msgothic.ttc 还是原版 —— 跑 deck games fonts install $bk"
    fi
  done < <(proton_dirs)
  say "  各 prefix："
  local id fd cnt=0 miss=0
  while IFS= read -r id; do
    fd="$(font_dir_of "$id")"
    if [ -z "$fd" ]; then
      printf '    - %s  （还没建 prefix —— 启动一次游戏后 run.sh 会自动补）\n' "$id"
      continue
    fi
    cnt=$((cnt + 1))
    local line="    · $id"
    for n in $PREFIX_NAMES; do
      if [ -L "$fd/$n" ] && [ "$(readlink "$fd/$n")" = "$TTC" ]; then
        line="$line ${n}✓"
      else
        line="$line ${n}✗"; miss=$((miss + 1))
      fi
    done
    say "$line"
  done < <(prefix_ids)
  [ "$cnt" = 0 ] && say "    （一个 prefix 都没找到）"
  if [ "$miss" != 0 ]; then
    say ""
    say "  有 $miss 个没就位 —— 跑：deck games fonts install"
  fi
  say ""
  say "  注意：游戏**要重启**才生效（字体在启动时枚举，进程活着就还是旧表）。"
}

cmd_install() {
  local only="${1:-}"
  need_ttc
  if [ "$only" = "--prefix" ]; then
    local id="${2:-}"; [ -n "$id" ] || die "用法：winfonts.sh install --prefix <compatdata号>"
    if [ -n "$(patch_prefix "$id")" ]; then
      say "  + prefix $id 已补 $PREFIX_NAMES"
    else
      say "  - prefix $id 还没有 windows\\Fonts（游戏启动一次后重跑）"
    fi
    return 0
  fi
  say "装到 Proton："
  patch_proton
  say "装到 prefix："
  local id fd done_=0 pending=0
  while IFS= read -r id; do
    fd="$(font_dir_of "$id")"
    if [ -z "$fd" ]; then pending=$((pending + 1)); continue; fi
    patch_prefix "$id" >/dev/null && { say "  + $id 补上 $PREFIX_NAMES"; done_=$((done_ + 1)); }
  done < <(prefix_ids)
  [ "$done_" = 0 ] && say "  （没有需要补的 prefix）"
  [ "$pending" != 0 ] && say "  （还有 $pending 个 prefix 没建好，游戏启动一次后重跑 install）"
  say ""
  say "完成 —— 游戏要**重启**才生效（正在跑的把游戏退出再进）。"
}

# ── ensure：给 run.sh 用的幂等自愈（后台跑，不出声）──
#   · Proton 更新/校验把 msgothic.ttc 换回去 → 下次启动游戏就会换回来
#   · 新游戏第一次启动才建 prefix → 用 --prefix 的话会等 Fonts 目录出现再补，
#     不必为了别的游戏白等，所以 run.sh 一定带 --prefix。
cmd_ensure() {
  local quiet="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet)  quiet=1 ;;
      --prefix) shift; id="${1:-}" ;;
    esac
    shift
  done
  [ -f "$TTC" ] || return 0
  patch_proton >/dev/null 2>&1

  if [ -n "$id" ]; then
    local fd waited=0
    while :; do
      fd="$(font_dir_of "$id")"
      if [ -n "$fd" ]; then patch_prefix "$id" >/dev/null 2>&1; break; fi
      waited=$((waited + 3))
      [ "$waited" -gt 45 ] && break       # 等 45 秒还没建 prefix 就算了，下次启动再说
      sleep 3
    done
    return 0
  fi

  local pid
  while IFS= read -r pid; do
    patch_prefix "$pid" >/dev/null 2>&1
  done < <(prefix_ids)
  return 0
}

cmd_remove() {
  local p t n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    t="$p/files/share/fonts/msgothic.ttc"
    if [ -f "$t.deckkit-orig" ]; then
      cp -p "$t.deckkit-orig" "$t" && rm -f "$t.deckkit-orig" && { say "  - 还原 ${p##*/}"; n=$((n + 1)); }
    fi
  done < <(proton_dirs)
  local id fd st
  while IFS= read -r id; do
    fd="$(font_dir_of "$id")"; st="$STATEDIR/$id.tsv"
    [ -n "$fd" ] || continue
    if [ -f "$st" ]; then
      while IFS=$'\t' read -r name kind val; do
        [ -n "$name" ] || continue
        rm -f "$fd/$name"
        case "$kind" in
          link)   ln -s "$val" "$fd/$name" 2>/dev/null && say "  - $id/$name 还原成符号链接" ;;
          file)   say "  ! $id/$name 原本是实体文件（已被替换），请自行还原" ;;
          absent) say "  - $id/$name 删除（原本不存在）" ;;
        esac
      done <"$st"
      rm -f "$st"
      n=$((n + 1))
    fi
  done < <(prefix_ids)
  [ "$n" = 0 ] && say "  （没什么可还原的）"
  say "完成。"
}

case "${1:-status}" in
  status|check)  cmd_status ;;
  install)       shift; cmd_install "${1:-}" "${2:-}" ;;
  ensure)        shift; cmd_ensure "$@" ;;
  remove|uninstall) cmd_remove ;;
  *) die "用法：winfonts.sh status|install [--prefix ID]|ensure [--prefix ID] [--quiet]|remove" ;;
esac
