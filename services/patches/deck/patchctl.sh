#!/usr/bin/env bash
# ============================================================
#  deckkit / patches —— Deck 侧执行体
#
#  在 Deck 上跑，被 `deck patches ...` 通过 ssh 调起来。也可以直接在 Deck 上跑：
#
#    patchctl.sh games                    已装的游戏（Steam + deckkit 自己装的，两种都算）
#    patchctl.sh list                     补丁库里的补丁 + 当前挂载状态
#    patchctl.sh state <补丁目录>          单个补丁的状态（mounted/clean/partial/unknown）
#    patchctl.sh kind <补丁目录>           kind 记录（installer / 空；读不到记录时非 0）
#    patchctl.sh mount <补丁目录>          挂载：把补丁文件覆盖进游戏目录（不备份原文件）
#    patchctl.sh unmount <补丁目录>        卸载：只告诉你还原办法（原文件没备份）
#    patchctl.sh verify <补丁目录>         逐文件 md5 核对
#    patchctl.sh remove <补丁目录> [--force]  从库里删除（挂载中会拒绝；
#                                         只接受 store/<appid>/<补丁> 这一层结构）
#    patchctl.sh resolve <补丁目录>        重算路径大小写/分隔符映射（挂载前自动做）
#    patchctl.sh menu                     给菜单栏用的行
#    patchctl.sh suggest                  库里还空着时，列几个已装游戏名当提示
#    patchctl.sh file-state <补丁目录> <相对路径> [md5]   单文件状态（排查用）
#    patchctl.sh fileinfo <文件>          单文件 <大小>\t<mtime>\t<md5>（排查用）
#    patchctl.sh find-sha <sha256>        按 sha256 找补丁（**没找到 = 输出空 + 退出码 0**，
#                                         退出码只表示「这条命令跑通了没」）
#
#  安装器型补丁用的几条：
#    patchctl.sh snapshot <目录>          目录快照（<相对路径>\t<大小>\t<mtime>）
#    patchctl.sh run-installer <appid> <exe> <起始目录>
#                                         用**游戏自己的 prefix**拉起补丁安装器（会开窗）
#    patchctl.sh manifest-from-install <补丁目录> <游戏目录> <before.tsv> <起始秒>
#                                         把"这次被动过的文件"变成 manifest.tsv
#
#  「挂载」= 把补丁 payload 里的文件覆盖进游戏目录：
#    · **不备份**被替换的原文件（用户要求）：Deck 上只留 manifest.tsv（路径+md5）用来算状态；
#      还原靠 Steam「验证文件完整性」（deckkit 管的非 Steam 游戏没有这一步，见 SERVICE.md）
#    · 覆盖用「写临时文件 + mv」原子替换，不留半截文件
#    · 状态是**算出来的**（比对 md5），不是记出来的 —— Steam「验证完整性」
#      把文件改回去以后，状态会自动变回「未挂载」，可以再点一次挂载
#    · 游戏目录有两个来源：Steam 的 steamapps/common/<installdir>；deckkit games 自己管的
#      （免安装 = 游戏目录，装 exe 的 = prefix 里主程序那一层）
#
#  公共件（消息函数 / 快照 / Proton 枚举 / 桌面会话环境）在
#  ~/deckkit/bin/deck-lib（由 `deck patches install` 推上来）。库缺失时走下面的
#  **兜底分支**：只补 patchctl 用到的几个，服务仍然跑得起来。
# ============================================================
set -uo pipefail

PATCH_ROOT="${PATCH_ROOT:-$HOME/deckkit/services/patches}"
# Proton / compatdata 的根。老代码叫 STEAM_DIR（可覆盖），库里的 Deck 通用件按
# DECK_STEAM 找 —— 在这里对齐一次，别让两边各算各的。
STEAM_DIR="${STEAM_DIR:-$HOME/.steam/steam}"
DECK_STEAM="${DECK_STEAM:-$STEAM_DIR}"

_lib="${HOME}/deckkit/bin/deck-lib"
if [ -r "$_lib" ]; then
  . "$_lib"
else
  # 兜底：库还没推上来也能跑。**内容刻意保持最小** —— 只覆盖这个脚本真正用到的
  # 那几个，真正的实现在 bin/deck-lib 里（别在这里加东西）。
  DECK_STEAM="${DECK_STEAM:-$HOME/.steam/steam}"
  ok()   { printf '  \xe2\x9c\x93 %s\n' "$*"; }
  warn() { printf '  ! %s\n' "$*"; }
  bad()  { printf '  \xe2\x9c\x97 %s\n' "$*"; }
  dim()  { printf '    %s\n' "$*"; }
  die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
  # 快照：exit 0 = find 跑通（输出可以为空），exit 1 = 目录不在/读不了。
  # 这个区分是必需的（见 cmd_snapshot 的注释），兜底也得是诚实的版本。
  deckkit_snapshot() {
    local dir="$1" out rc
    [ -d "$dir" ] || return 1
    out="$(find "$dir" -type f -printf '%P\t%s\t%T@\n' 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return 1
    [ -n "$out" ] && printf '%s\n' "$out" | sort
    return 0
  }
  # usage 从头部注释块现算（等价于库里那个）
  deckkit_usage_of() { sed -n '2,/^[^#]/p' "$1" 2>/dev/null | sed -n 's/^# \{0,1\}//p'; }
  deckkit_human() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN{ split("B KiB MiB GiB TiB",u," "); i=1; while (b>=1024 && i<5){b/=1024;i++} printf (i==1?"%d %s":"%.1f %s"), b, u[i] }'
  }
  deckkit_compat_dir()  { printf '%s/steamapps/compatdata' "$DECK_STEAM"; }
  deckkit_protons_dir() { printf '%s/steamapps/common' "$DECK_STEAM"; }
  deckkit_protons() {
    local d
    for d in "$(deckkit_protons_dir)"/Proton*; do
      [ -d "$d" ] || continue
      [ -x "$d/proton" ] && basename "$d"
    done
  }
  deckkit_pick_proton() {
    [ -n "${PROTON:-}" ] && { printf '%s' "$PROTON"; return 0; }
    local p
    p="$(deckkit_protons | grep -E '^Proton [0-9]' | sort -t' ' -k2 -V | tail -1)"
    [ -n "$p" ] || p="$(deckkit_protons | grep -i experimental | head -1)"
    [ -n "$p" ] || p="$(deckkit_protons | head -1)"
    [ -n "$p" ] || return 1
    printf '%s' "$p"
  }
  # 桌面会话探测是公共库那部分的活儿，兜底不复制：读不到 DISPLAY 时
  # cmd_run_installer 会明确报错并提示跑 `deck patches install`。
  deckkit_display_env() { :; }
fi

STORE="$PATCH_ROOT/store"
COMPAT="$(deckkit_compat_dir)"
PROTONS_DIR="$(deckkit_protons_dir)"
INSTALLER_LOG="$PATCH_ROOT/installer.log"
# 日志走统一入口（~/deckkit/bin/deck-log，由 `deck patches install` 一起推上来）：
# 位置/格式/滚动定在一处，读的时候 Mac 上 `deck logs patches-installer` 直接就有。
# 工具不在就退回老路径 —— 日志是辅助，不该成为依赖。
DECK_LOG_TOOL="${HOME}/deckkit/bin/deck-log"
if [ -x "$DECK_LOG_TOOL" ]; then
  _dklog_path="$("$DECK_LOG_TOOL" --path patches-installer 2>/dev/null)"
  [ -n "${_dklog_path:-}" ] && INSTALLER_LOG="$_dklog_path"
fi

# ------------------------------------------------------------ 游戏枚举 ---
# 库位置可能不止一个（SD 卡等），都能从 libraryfolders.vdf 里读到。
steam_libraries() {
  # ~/.steam/steam 与 ~/.local/share/Steam 是同一个目录（符号链接），
  # 不去重的话每个游戏会被数两遍 —— 匹配时会误判成「并列」。
  local vdf="$STEAM_DIR/steamapps/libraryfolders.vdf"
  { [ -f "$vdf" ] && sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf"
    printf '%s\n' "$STEAM_DIR"; } | while IFS= read -r p; do readlink -f "$p"; done | sort -u
}

# Proton / Steam Linux Runtime / 兼容层不是游戏，别列进来
is_runtime() {
  case "$1" in
    *Proton*|*SteamLinuxRuntime*|*"Steam Linux Runtime"*|*"Steamworks Common Redistributables"*|*"Steamworks Shared"*) return 0 ;;
  esac
  return 1
}

# deckkit 自己装的非 Steam 游戏（没有 appmanifest，Steam 那边看不见）：
#   ~/deckkit/services/games/store/<slug>/meta.tsv
#     portable=1 → game_dir 就是游戏根目录（免安装：整份拷过去的）
#     否则       → game_exe 在 prefix 里，游戏根目录 = dirname(game_exe)（安装包装的）
# id 直接用 deckkit 记的 appid：它是 crc32|0x80000000，**永远 ≥ 2^31**，
# 而 Steam 的 appid 都 < 2^31，所以两者绝不会撞号。
cmd_deckkit_games() {
  local d appid name dir exe sz
  for d in "$HOME"/deckkit/services/games/store/*/; do
    [ -f "$d/meta.tsv" ] || continue
    appid="$(sed -n 's/^appid=//p' "$d/meta.tsv" | head -1)"
    name="$(sed -n 's/^name=//p' "$d/meta.tsv" | head -1)"
    dir="$(sed -n 's/^game_dir=//p' "$d/meta.tsv" | head -1)"
    if [ -z "$dir" ]; then
      exe="$(sed -n 's/^game_exe=//p' "$d/meta.tsv" | head -1)"
      [ -n "$exe" ] && dir="$(dirname "$exe")"
    fi
    [ -n "$appid" ] && [ -n "$name" ] && [ -n "$dir" ] && [ -d "$dir" ] || continue
    # 体积优先用记录里的 —— cmd_games 被 list/status/menu/suggest 反复调用，
    # 每个游戏都递归 du 会让菜单栏每 30 秒一轮都在等它（review 抓到）。
    # 记录里没有才退回 du（只有老记录会走到这里）。
    sz="$(sed -n 's/^size=//p' "$d/meta.tsv" | head -1)"
    [ -n "$sz" ] || sz="$(sed -n 's/^prefix_size=//p' "$d/meta.tsv" | head -1)"
    [ -n "$sz" ] || sz="$(du -sh "$dir" 2>/dev/null | cut -f1)"
    printf '%s\t%s\t%s\t%s\n' "$appid" "$name" "$dir" "$sz"
  done
}

# 输出：appid \t 名字 \t 游戏目录 \t 大小（Steam 游戏 + deckkit 自己装的游戏）
cmd_games() {
  local lib acf id name dir full sz
  # 库路径按**行**读：`for lib in $(steam_libraries)` 会把含空格的库路径
  # 拆成两个词（review 抓到），而库路径里带空格是合法的。
  while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    [ -d "$lib/steamapps" ] || continue
    for acf in "$lib"/steamapps/appmanifest_*.acf; do
      [ -f "$acf" ] || continue
      id="$(basename "$acf" | sed 's/^appmanifest_//; s/\.acf$//')"
      name="$(sed -n 's/.*"name"[[:space:]]*"\([^"]*\)".*/\1/p' "$acf" | head -1)"
      dir="$(sed -n 's/.*"installdir"[[:space:]]*"\([^"]*\)".*/\1/p' "$acf" | head -1)"
      [ -n "$dir" ] || continue
      full="$lib/steamapps/common/$dir"
      [ -d "$full" ] || continue
      is_runtime "$dir" && continue
      # 体积优先读 acf 里的 SizeOnDisk（Steam 自己记的字节数，零 I/O）。
      # 以前这里无条件 `du -sh` 每个游戏目录 —— cmd_games 被
      # list/status/menu/suggest 反复调用，菜单栏每 30 秒一轮都要在 Deck 上
      # 递归遍历几十上百 GB 的目录（review 抓到）。
      sz="$(sed -n 's/.*"SizeOnDisk"[[:space:]]*"\([0-9][0-9]*\)".*/\1/p' "$acf" | head -1)"
      if [ -n "$sz" ]; then sz="$(deckkit_human "$sz")"
      else sz="$(du -sh "$full" 2>/dev/null | cut -f1)"; fi
      printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$full" "$sz"
    done
  done < <(steam_libraries)
  cmd_deckkit_games
}

# appid 或（唯一的）名字 → 游戏目录
resolve_game() {
  local want="$1" id name dir hit=""
  while IFS=$'\t' read -r id name dir _sz; do
    if [ "$id" = "$want" ] || [ "$name" = "$want" ]; then hit="$dir"; break; fi
  done < <(cmd_games)
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}

# ------------------------------------------------------------- 补丁库 ---
patch_dirs() {
  [ -d "$STORE" ] || return 0
  # 只排除以点开头的（旧规则是 [a-z0-9]*，那会把中日文短名的补丁整个藏起来 —— 实测踩过：
  # slugify 允许中日文之后，"MyGame2-汉化补丁" 在 list/status 里根本看不见）
  find "$STORE" -mindepth 2 -maxdepth 2 -type d -name '[!.]*' 2>/dev/null | sort
}

# 补丁目录 → id（appid/slug）。
# 只在前缀真的匹配时剥：`${1#$STORE/}` 在匹配不上时原样返回 —— 一个绝对路径
# 会被当成 id 打印/回给 Mac（review 抓到）。
patch_id() {
  local p="${1%/}"
  case "$p" in
    "$STORE"/*) printf '%s' "${p#$STORE/}" ;;
    *)          printf '%s' "$p" ;;
  esac
}

meta_get() { sed -n "s/^$2=//p" "$1/meta.tsv" 2>/dev/null | head -1; }

# 补丁目录 → 游戏名（读游戏级记录 store/<appid>/.game）。
# 逐文件路径上要用的是 game_dir_of（见下面）—— 两者都"每次读一次文件"，
# 缓存不了（被 $(...) 调用，赋值活不过子 shell）；真正省掉重复 I/O 的地方在
# cmd_state / cmd_verify：它们把 gdir + resolved 映射一次性预读进变量。
game_name_of() {
  local appid; appid="$(basename "$(dirname "$1")")"
  sed -n 's/^name=//p' "$STORE/$appid/.game" 2>/dev/null | head -1
}

# payload 里是否有大文件：状态用 md5 还是用大小（大 payload 上 md5 太慢）
# 注意：**不要指望在它里面做缓存** —— 它被 `$(...)` 调用（子 shell），
# 缓存赋值出了子 shell 就没了。真正的修法在 cmd_state：那里只调它一次。
use_hash() {
  local patch="$1" total=0 rel md5 size
  while IFS=$'\t' read -r rel md5 size; do
    [ -n "${size:-}" ] || continue
    total=$((total + size))
  done < "$patch/manifest.tsv"
  [ "$total" -le 536870912 ]      # 512 MiB 以内用 md5
}


# game_dir_of / target_of 保持简单（每次读一次文件）。**别在这里做缓存** ——
# 它们被 `$(...)` 调用，缓存赋值活不过子 shell。
# cmd_state / cmd_verify 是"逐文件"的调用方，它们自己把 gdir + resolved 映射
# 预读进变量，循环里不走这两个函数（1400+ 文件的补丁实测差别是几十秒）。
game_dir_of() {
  local appid; appid="$(basename "$(dirname "$1")")"
  sed -n 's/^dir=//p' "$STORE/$appid/.game" 2>/dev/null | head -1
}
target_of() {
  local patch="$1" rel="$2"
  local map="$patch/resolved.tsv"
  if [ -f "$map" ]; then
    local hit; hit="$(REL="$rel" awk -F'	' '$1==ENVIRON["REL"]{print $2; exit}' "$map")"
    [ -n "$hit" ] && { printf '%s/%s' "$(game_dir_of "$patch")" "$hit"; return 0; }
  fi
  printf '%s/%s' "$(game_dir_of "$patch")" "$rel"
}

cmd_resolve() {
  local patch="${1%/}" gdir; gdir="$(game_dir_of "$patch")"
  local rel md5 size cur seg out fixed=0
  : > "$patch/resolved.tsv"
  while IFS=$'\t' read -r rel md5 size; do
    [ -n "${rel:-}" ] || continue
    rel="${rel//\\\\//}"          # 反斜杠归一成 /
    cur="$gdir"; out=""
    local IFS='/'
    for seg in $rel; do
      [ -n "$seg" ] || continue
      if [ -e "$cur/$seg" ]; then out="${out:+$out/}$seg"; cur="$cur/$seg"; continue; fi
      local alt; alt="$(find "$cur" -maxdepth 1 -iname "$seg" 2>/dev/null | head -1)"
      if [ -n "$alt" ]; then
        out="${out:+$out/}$(basename "$alt")"; cur="$alt"; fixed=$((fixed + 1))
      else
        out="${out:+$out/}$seg"; cur="$cur/$seg"
      fi
    done
    printf '%s\t%s\n' "$rel" "$out" >> "$patch/resolved.tsv"
  done < "$patch/manifest.tsv"
  [ "$fixed" -gt 0 ] && printf '  路径纠正：%s 段按真实文件系统的大小写改名\n' "$fixed"
  return 0
}

# 单个文件现在处于什么状态：payload / absent / other。
# **没有 original**：按用户要求不备份原文件，所以"不是补丁版本"只能叫 other
# （原版 / 被 Steam 还原 / 别的程序改过，三者分不出来）。
# 注意：cmd_verify 走的是"预读版"（一次读 gdir+resolved 再循环，见那个函数），
# 不再逐文件调这里；这个函数留给单文件排查用（file-state 子命令）。
file_state() {
  #   payload = 这个文件当前就是补丁版本
  #   absent  = 文件不存在
  #   other   = 既不是补丁版本
  local patch="$1" rel="$2" want_md5="$3"
  local target; target="$(target_of "$patch" "$rel")"
  [ -e "$target" ] || { printf 'absent'; return 0; }
  if use_hash "$patch"; then
    [ "$(md5sum "$target" 2>/dev/null | cut -d' ' -f1)" = "$want_md5" ] && printf 'payload' || printf 'other'
  else
    local tsz psz; tsz="$(stat -c%s "$target" 2>/dev/null)"
    psz="$(REL="$rel" awk -F'\t' '$1==ENVIRON["REL"]{print $3}' "$patch/manifest.tsv" | head -1)"
    [ "$tsz" = "$psz" ] && printf 'payload' || printf 'other'
  fi
}
# 整个补丁的状态：mounted（全部是 payload）/ clean（全部是原始）/ partial / unknown
#
# **性能**：这里原来对每个文件都调 file_state → target_of → game_dir_of，
# 每层都是 `$(...)` 子 shell，于是 use_hash/game_dir_of 的缓存**根本不生效**
# （子 shell 里的赋值出了子 shell 就没了）。1467 个文件的补丁 = 1467 次
# 重读 manifest + 1467 次重读 .game，实测单这一个补丁就要 50 秒；
# `list` 和 `status` 各走一遍 → `deck brief`（菜单栏/游戏管理页每次都调）要 100 秒。
# 所以改成：**先一次性把 gdir、hash 策略、路径映射读到变量里**，循环里只做
# 真正必需的 md5sum，不再有任何子 shell 里的重复 I/O。
# ── 目标文件状态扫描 ──────────────────────────────────────────────────
# 按 manifest 顺序输出每个目标文件现在是什么状态，一行一个：payload / absent / other。
#
# 为什么要整批做：以前是**每个文件 fork 一次**（`stat -c%s` 或 `md5sum`）。
# 实测一个 1467 文件的补丁要 1611 次 fork、6.4 秒 CPU —— 而菜单栏每 30 秒就问一次
# 状态，等于让 Deck 白烧 0.43 核。同一件事在一个进程里做完是毫秒级。
#
# 两个实现：
#   · 快路 python3（Deck 自带，games 那边早就依赖它）
#   · 慢路纯 bash（没有 python3 的机器照旧能用 —— 正确但慢，不做成硬依赖）
# 两条路都**只往 stdout 输出 ASCII 状态词**，路径一律不经过 stdout：Deck 的
# locale 是 POSIX（实测 LC_CTYPE=POSIX），让路径往返一趟编码很容易出幺蛾子。
state_scan() {   # <补丁目录> <hash_mode 0|1>
  if command -v python3 >/dev/null 2>&1; then
    state_scan_py "$@"
  else
    state_scan_slow "$@"
  fi
}

# 快路。全程 **bytes**：manifest / resolved / .game / 文件路径都按字节处理，
# 于是完全不看 locale（中文日文路径在任何 locale 下都对），os.stat 也不会因为
# fsencode 碰到非法字符而抛 UnicodeEncodeError。
state_scan_py() {
  python3 - "$1" "$2" <<'PY'
import hashlib, os, sys

patch = os.fsencode(sys.argv[1].rstrip("/"))
hash_mode = len(sys.argv) > 2 and sys.argv[2] == "1"

# resolved.tsv：路径大小写/分隔符纠正表（补丁是 Windows 语义，Deck 敏感）
res = {}
p = os.path.join(patch, b"resolved.tsv")
if os.path.exists(p):
    with open(p, "rb") as f:
        for line in f:
            a, _, b = line.rstrip(b"\r\n").partition(b"\t")
            if a:
                res[a] = b

# 游戏目录在**上一层**的 .game 里（store/<appid>/<补丁>/ → store/<appid>/.game）
gdir = b""
p = os.path.join(os.path.dirname(patch), b".game")
if os.path.exists(p):
    with open(p, "rb") as f:
        for line in f:
            line = line.strip()
            if line.startswith(b"dir="):
                gdir = line[4:]
                break

states = []
with open(os.path.join(patch, b"manifest.tsv"), "rb") as f:
    for line in f:
        parts = line.rstrip(b"\r\n").split(b"\t")
        if not parts or not parts[0]:
            continue                      # 空行/空路径：和 bash 那边一样跳过
        rel = parts[0]
        md5 = parts[1] if len(parts) > 1 else b""
        size = parts[2] if len(parts) > 2 else b""
        tgt = gdir + b"/" + res.get(rel, rel)
        if not os.path.exists(tgt):       # 与 bash 的 [ -e ] 同义（断链符号链接算不在）
            states.append("absent")
            continue
        if hash_mode:
            try:
                h = hashlib.md5()
                with open(tgt, "rb") as g:
                    for chunk in iter(lambda: g.read(1 << 20), b""):
                        h.update(chunk)
                states.append("payload" if h.hexdigest().encode("ascii") == md5 else "other")
            except OSError:
                states.append("other")
        else:
            try:
                states.append("payload" if os.stat(tgt).st_size == int(size) else "other")
            except (OSError, ValueError):
                states.append("other")

sys.stdout.write("".join(x + "\n" for x in states))
PY
}

# 慢路（没有 python3 时）：逐文件 fork，和以前一样。留着是为了「不因为缺个解释器
# 就不干活」，正常情况下不该走到这里。
state_scan_slow() {
  local patch="$1" hash_mode="$2" rel md5 size tgt
  local gdir; gdir="$(game_dir_of "$patch")"
  declare -A _resolve=()
  if [ -f "$patch/resolved.tsv" ]; then
    while IFS=$'\t' read -r _a _b; do
      [ -n "${_a:-}" ] && _resolve[$_a]="$_b"
    done < "$patch/resolved.tsv"
  fi
  while IFS=$'\t' read -r rel md5 size; do
    [ -n "${rel:-}" ] || continue
    tgt="${_resolve[$rel]:-}"
    if [ -n "$tgt" ]; then tgt="$gdir/$tgt"; else tgt="$gdir/$rel"; fi
    if [ ! -e "$tgt" ]; then printf 'absent\n'; continue; fi
    if [ "$hash_mode" = 1 ]; then
      if [ "$(md5sum "$tgt" 2>/dev/null | cut -d' ' -f1)" = "$md5" ]; then printf 'payload\n'; else printf 'other\n'; fi
    else
      if [ "$(stat -c%s "$tgt" 2>/dev/null)" = "$size" ]; then printf 'payload\n'; else printf 'other\n'; fi
    fi
  done < "$patch/manifest.tsv"
}

cmd_state() {
  local patch="${1%/}" st i=0 n_all=0 n_pay=0
  [ -f "$patch/manifest.tsv" ] || { printf 'unknown'; return 0; }
  # manifest 可能是空的（安装器型补丁：装完一个文件都没变）—— 那叫「未知」，
  # 不是「已挂载」（0 == 0 会误判成 mounted，然后 remove 就被自己的守卫拦住了）
  [ -s "$patch/manifest.tsv" ] || { printf 'unknown'; return 0; }

  local hash_mode=0
  use_hash "$patch" && hash_mode=1      # 只累加一次 manifest

  # 一次问完所有目标文件的状态（见 state_scan：这是原来最贵的一步）
  local -a states=()
  while IFS= read -r st; do states+=("$st"); done < <(state_scan "$patch" "$hash_mode")

  local rel md5 size
  while IFS=$'\t' read -r rel md5 size; do
    [ -n "${rel:-}" ] || continue
    n_all=$((n_all + 1))
    st="${states[$i]:-}"; i=$((i + 1))
    [ "$st" = payload ] && n_pay=$((n_pay + 1))
  done < "$patch/manifest.tsv"

  # 扫描结果条数对不上清单 = 没算完（python 崩了 / manifest 半路变了）——
  # 报「未知」而不是猜一个 mounted/clean（未知在 Mac 侧算「异常」，会被看见）
  [ "$i" = "${#states[@]}" ] || { printf 'unknown'; return 0; }

  if [ "$n_pay" = "$n_all" ]; then printf 'mounted'
  elif [ "$n_pay" = 0 ]; then printf 'clean'          # 全是「不是补丁版本」= 未挂载
  else printf 'partial'; fi
}

state_text() {
  case "$1" in
    mounted) printf '已挂载' ;;
    clean)   printf '未挂载' ;;
    partial) printf '部分挂载' ;;
    *)       printf '状态未知' ;;
  esac
}

# 每个补丁的状态行（**一次算完**）：
#   <id>\t<游戏>\t<状态文本>\t<内部状态>\t<文件数>
# list 和 status 共用它 —— 以前 status 内部要算一遍、然后 Mac 侧又调一次 list
# 再算一遍（同一份 md5 走两趟，一轮里白烧 6 秒）。
patch_state_rows() {
  local patch id st gname files
  [ -d "$STORE" ] || return 0
  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    id="$(patch_id "$patch")"
    st="$(cmd_state "$patch")"
    gname="$(game_name_of "$patch")"
    files="$(wc -l < "$patch/manifest.tsv" 2>/dev/null | tr -d ' ')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$gname" "$(state_text "$st")" "$st" "$files"
  done < <(patch_dirs)
}

cmd_list() {
  # 库不存在时**什么也不打印**：这些行是给 Mac 侧解析的（<id>\t<游戏>\t…），
  # 以前打的 `(补丁库是空的)` 不含 tab，Mac 那边 `grep -c .` 会把它数成
  # 「1 个补丁」（review 抓到）。人要看空库提示，走 Mac 侧的 status。
  patch_state_rows
}

# 按 sha256 找库里的补丁（Mac 侧 mount-file 用：同一个 exe 只入库一次）。
# **没找到 = 输出为空 + 退出码 0**：退出码只回答「这条命令跑通了没」。
# 以前没找到返回 1，和 ssh/工具失败同一个码，Mac 侧一个 `|| true` 就把两者都
# 当成「库里没有」→ 白走一遍入库（重复入库，review 抓到）。
cmd_find_sha() {
  local want="$1" p sum
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    sum="$(meta_get "$p" sha256)"
    [ -n "$sum" ] && [ "$sum" = "$want" ] && { patch_id "$p"; break; }
  done < <(patch_dirs)
  return 0
}

# 库里还没有补丁时，给几个已装游戏名当提示
cmd_suggest() {
  local gid gname gdir n=0
  while IFS=$'\t' read -r gid gname gdir _sz; do
    [ -n "${gid:-}" ] || continue
    printf '  %s（%s）\n' "$gname" "$gid"
    n=$((n + 1)); [ "$n" -ge 8 ] && break
  done < <(cmd_games)
  return 0
}

# --------------------------------------------------------------- mount ---

cmd_mount() {
  local patch="${1%/}" rel md5 size src target tmp n=0
  [ -d "$patch" ] || die "没有这个补丁目录：$patch"
  [ -f "$patch/manifest.tsv" ] || die "缺少 manifest.tsv"
  local gdir; gdir="$(game_dir_of "$patch")"
  [ -d "$gdir" ] || die "游戏目录不存在：${gdir}（游戏被卸载/移动了？）"

  cmd_resolve "$patch"      # 路径逐段按真实文件系统纠正（大小写/分隔符）

  # 按用户要求：**不备份**被替换的文件。覆盖用「临时文件 + mv」原子替换，
  # 想还原就用 Steam 的「验证文件完整性」。
  while IFS=$'\t' read -r rel md5 size; do
    [ -n "${rel:-}" ] || continue
    src="$patch/payload/$rel"
    target="$(target_of "$patch" "$rel")"
    [ -f "$src" ] || { warn "payload 缺文件，跳过：$rel"; continue; }
    # 目标已经是目录时 `mv -f tmp target` 会**把 tmp 搬进那个目录里**（名字对不上，
    # 等于挂了个空气）—— 直接跳过并说清楚（review 抓到）。
    if [ -d "$target" ]; then
      warn "目标是目录（清单里写的是文件），跳过：$rel"
      continue
    fi
    mkdir -p "$(dirname "$target")"
    tmp="$(dirname "$target")/.deckkit-patch-new.$$"
    cp -p "$src" "$tmp" || die "写入失败：$target"
    mv -f "$tmp" "$target" || die "替换失败：$target"
    n=$((n + 1))
  done < "$patch/manifest.tsv"
  date '+%Y-%m-%d %H:%M:%S' > "$patch/mounted_at"
  ok "已挂载 $(basename "$(dirname "$patch")")/$(basename "$patch")：覆盖 $n 个文件"
  dim "游戏目录 ${gdir}（未备份原文件；要还原：Steam → 验证文件完整性）"
}

cmd_unmount() {
  local patch="${1%/}" gdir
  gdir="$(game_dir_of "$patch")"
  warn "按配置不备份原始文件，本地没有东西可还原"
  dim "游戏目录 ${gdir}"
  # 还原办法取决于这是谁的游戏：Steam 游戏有「验证文件完整性」，
  # deckkit 自己装的非 Steam 游戏**没有**这一步（Steam 不认它的文件），
  # 只能回 Mac 重新拷一份 —— 直说的话比让人白找半天强。
  case "$gdir" in
    */steamapps/common/*)
      dim "还原办法：Steam → 该游戏 → 属性 → 已安装文件 → 验证文件完整性"
      dim "（验证完这里的状态会自动变回「未挂载」，之后可以重新挂载）" ;;
    *)
      dim "这是 deckkit 自己装的非 Steam 游戏，Steam 没有它的文件校验。还原办法："
      dim "  回 Mac 重新拷一份 —— deck games rm <名字> && deck games add '<原目录|安装包>'" ;;
  esac
  return 0
}

# 逐文件核对。**性能**：和 cmd_state 一样，先把 gdir / hash 策略 / resolved 映射
# 一次性读进变量，循环里只剩 md5sum（或 stat）。老写法每个文件都走
# file_state → target_of → game_dir_of，全是 $(...) 子 shell，
# 1400+ 文件的补丁要几十秒（review 抓到）。
# 统计只有三类：payload / other（非补丁版本）/ absent。
# 老代码里还有个 `original` 分支 —— 不备份原文件，那个分支**永远不可达**。
cmd_verify() {
  local patch="${1%/}" rel md5 size st i=0 pay=0 other=0 absent=0 n_all=0
  [ -f "$patch/manifest.tsv" ] || die "缺少 manifest.tsv：$patch"
  local gdir; gdir="$(game_dir_of "$patch")"
  [ -n "$gdir" ] || die "读不到游戏目录（$patch 下没有 .game？）"
  local hash_mode=0
  use_hash "$patch" && hash_mode=1

  # 同一份批量扫描（以前这里也是每文件 fork 一次 → 1467 个文件 47.5 秒）
  local -a states=()
  while IFS= read -r st; do states+=("$st"); done < <(state_scan "$patch" "$hash_mode")

  while IFS=$'\t' read -r rel md5 size; do
    [ -n "${rel:-}" ] || continue
    n_all=$((n_all + 1))
    st="${states[$i]:-}"; i=$((i + 1))
    case "$st" in
      payload) pay=$((pay + 1)) ;;
      absent)  absent=$((absent + 1)); warn "清单里有、游戏目录里没有：$rel" ;;
      *)       other=$((other + 1))
               if [ "$hash_mode" = 1 ]; then warn "与补丁不同：$rel"
               else warn "与补丁不同（按大小）：$rel"; fi ;;
    esac
  done < "$patch/manifest.tsv"

  [ "$i" = "${#states[@]}" ] || die "扫描没算完（结果 $i 条，清单 $n_all 条）—— 重跑一次再判断"
  printf '  补丁版本 %s  非补丁版本 %s  缺失 %s（共 %s）\n' "$pay" "$other" "$absent" "$n_all"
  [ "$n_all" -gt 0 ] && [ "$pay" = "$n_all" ] && ok "校验：已完整挂载"
  [ "$pay" = 0 ] && ok "校验：当前不是补丁版本（未挂载 / 已被 Steam 还原）"
  return 0
}

cmd_remove() {
  local patch="${1%/}" force="${2:-}"
  # 先确认目录真的在：`rm -rf` 对不存在的路径是**静默成功**的 ——
  # 之前拿被 ~ 祸害过的路径来删，就报了个假的「已从补丁库删除」（实测）。
  [ -d "$patch" ] || die "找不到这个补丁目录：$patch"
  # §6 第一道阀：**必须是 store/<appid>/<补丁> 这一层结构**。
  # 以前只校验「目录存在」—— `patchctl.sh remove <store 根>` 就是把整个补丁库
  # rm -rf 掉（review 抓到），`remove <某个 appid 目录>` 会连 .game 一起删。
  case "$patch" in
    "$STORE"/?*/?*) ;;
    *) die "路径不是 store/<appid>/<补丁>，拒绝删除：$patch" ;;
  esac
  case "$patch" in *..*) die "路径里有 ..，拒绝删除：$patch" ;; esac
  local st; st="$(cmd_state "$patch")"
  # 挂载中 / 部分挂载时默认拒绝：删了记录就再没有还原提示了。
  # 但**不能是死路** —— 安装器型补丁里「内容没变却被动过」的文件会一直是
  # 「补丁版本」，状态会永远停在部分挂载（见 SERVICE.md 已知边界），
  # 所以给一个必须显式打出来的 --force。
  if [ "$st" = "mounted" ] || [ "$st" = "partial" ]; then
    if [ "$force" != "--force" ]; then
      die "当前是「$(state_text "$st")」—— 确认游戏文件已经还原（Steam 验证完整性 / 回 Mac 重拷）之后再删：
       deck patches remove $(patch_id "$patch") --yes --force"
    fi
    warn "游戏里可能还留着补丁文件；记录删掉后就没有还原提示了"
  fi
  rm -rf "$patch" || die "删除失败"
  # 该游戏下最后一个补丁删掉后，别留空目录（.game 是游戏级记录，跟着一起走）
  local gd; gd="$(dirname "$patch")"
  if [ -z "$(ls -A "$gd" 2>/dev/null | grep -v '^\.game$')" ]; then
    rm -f "$gd/.game"; rmdir "$gd" 2>/dev/null
  fi
  ok "已从补丁库删除：$(basename "$patch")"
}

# 给菜单栏用：<组>\t<标签>\t<参数>\t<提示>
cmd_menu() {
  local patch id st gname files label
  if [ ! -d "$STORE" ] || [ -z "$(patch_dirs)" ]; then
    printf '\t（补丁库是空的）\t\t在 Mac 上跑：deck patches add <补丁.exe>\n'
    return 0
  fi
  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    id="$(patch_id "$patch")"
    st="$(cmd_state "$patch")"
    gname="$(game_name_of "$patch")"
    files="$(wc -l < "$patch/manifest.tsv" 2>/dev/null | tr -d ' ')"
    if [ "$st" = "mounted" ]; then
      label="$(meta_get "$patch" name)  ✓ 已挂载"
      # 文案要说真话：挂载**不备份原文件**（用户要求），所以「卸载」在这里
      # 只能是「告诉你还原办法」—— 点一下并不会把游戏文件还原回去。
      # 写「点一下卸载（还原原始文件）」是假承诺，用户点了会发现什么都没变。
      printf '%s\t%s\ttoggle %s\t点一下看还原办法（不备份原文件）· %s 个文件\n' "$gname" "$label" "$id" "$files"
    else
      label="$(meta_get "$patch" name)  · 未挂载"
      printf '%s\t%s\ttoggle %s\t点一下挂载（覆盖 %s 个文件）\n' "$gname" "$label" "$id" "$files"
    fi
  done < <(patch_dirs)

  # 顺带提示：哪些已安装游戏还没有补丁（只列最前面几个，避免菜单过长）
  local gid gname2 gdir n=0
  while IFS=$'\t' read -r gid gname2 gdir _sz; do
    [ -n "${gid:-}" ] || continue
    [ -d "$STORE/$gid" ] && continue
    [ "$n" -ge 3 ] && break
    printf '\t%s（还没有补丁）\t\t在 Mac 上跑：deck patches add <补丁.exe>\n' "$gname2"
    n=$((n + 1))
  done < <(cmd_games)
}

# 一屏状态（给 `deck patches status` 的第二段）
cmd_status() {
  # --tsv：面板之后多打一段 `@@TSV` + 状态行，让 Mac 侧**一次远程调用**同时拿到
  # 「人要看的」和「要计数的」。不带这个开关时输出和以前一模一样。
  local want_tsv=0
  case "${1:-}" in
    --tsv) want_tsv=1 ;;
    "")    ;;
    *)     die "status 只认 --tsv" ;;
  esac
  local rows; rows="$(patch_state_rows)"
  printf '补丁库  %s\n' "$STORE"
  if [ -z "$rows" ]; then
    warn "补丁库是空的（Mac 上：deck patches add <补丁.exe>）"
  else
    local id gname stext stk files patch srcinfo
    while IFS=$'\t' read -r id gname stext stk files; do
      [ -n "${id:-}" ] || continue
      # 符号要跟着状态走（约定 §2：✓ 正常 / ! 注意 / ✗ 出错）。以前一律 `ok`，
      # 于是「部分挂载」「状态未知」也挂着一个 ✓ —— 摘要行说「异常 1」、
      # 明细行却全是绿的，自相矛盾。
      case "$stk" in
        mounted|clean) ok   "$id  ${gname}  ${stext}" ;;
        partial)       warn "$id  ${gname}  ${stext}" ;;
        *)             bad  "$id  ${gname}  ${stext}" ;;
      esac
      patch="$STORE/$id"
      if [ -f "$patch/patch.exe" ]; then srcinfo="exe $(du -h "$patch/patch.exe" | cut -f1)"
      elif [ "$(meta_get "$patch" source)" = "dir" ]; then srcinfo="文件夹入库（无 exe）"
      else srcinfo="exe 缺失"; fi
      # manifest 可能不存在（记录坏了）：wc 的 stderr 别丢，否则这里会报一个空的数字
      dim "$(wc -l < "$patch/manifest.tsv" 2>/dev/null | tr -d ' ') 个文件 · payload $([ -d "$patch/payload" ] && du -sh "$patch/payload" 2>/dev/null | cut -f1 || echo '不在 Deck（按配置不留）') · $srcinfo"
    done <<EOF
$rows
EOF
  fi
  if [ "$want_tsv" = 1 ]; then
    printf '@@TSV\n%s' "$rows"
  fi
}

# ------------------------------------------- 安装器型补丁（⚠️ 未实测）-------
# 「带安装器的补丁」解不出文件清单，只能真把它跑起来：
#   · 用**游戏自己的 prefix**（很多补丁的安装脚本要读游戏写下的注册表键才认出游戏目录；
#     换个 prefix 就会出现「装完了但游戏目录一个字节都没变」——games 那边实测过这个坑）
#   · cwd = 游戏目录，向导里默认路径就落在对的地方
#   · 安装前后对游戏目录做快照，被动过且**内容真的变了**的文件写进 manifest.tsv
#     —— 之后 state / verify / list 全套沿用「文件包」型那一套，不用另写状态机
# 这段是照着 games 的安装器流程（cmd_run / snapshot / diff）同源实现的，
# 但**还没有真实样本跑过**：第一次用请盯着日志和「安装结果」那几行。

# 目录快照：<相对路径>\t<大小>\t<mtime（%T@，带小数）>，按路径排序。
# 直接用公共库的 deckkit_snapshot —— **它的退出码是诚实的**：
#   exit 0 = find 真跑通了（输出可以是空的：空目录本来就是合法结果）
#   exit 1 = 目录不在 / 读不了
# 老写法是 `find … 2>/dev/null | sort`：管道退出码来自 sort（恒 0），
# 调用方的 `|| die "快照失败"` 永远不触发 —— 空快照被当成「安装前后一个文件
# 都没变」，把执行失败报成「安装器没装进去」（review 抓到）。
cmd_snapshot() {
  deckkit_snapshot "${1%/}"
}

# 单个文件 → <大小>\t<mtime 秒>\t<md5>
cmd_fileinfo() {
  local f="$1"
  [ -f "$f" ] || return 0
  printf '%s\t%s\t%s\n' "$(stat -c%s "$f" 2>/dev/null)" \
    "$(stat -c%Y "$f" 2>/dev/null)" "$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"
}

# Proton 枚举 / 挑选用公共库的 deckkit_protons / deckkit_pick_proton（原来这里
# 各有一份拷贝，和 gamectl.sh 那份已经分叉过）。它认 PROTON 环境变量。
# 只留一个别名，免得下面 cmd_run_installer 那几行跟着改：
pick_proton() { deckkit_pick_proton; }

# 用游戏自己的 prefix 拉起补丁安装器。输出写日志文件，不继承 ssh 管道
# （proton 的子进程抓着管道不放会让 ssh 一直不返回，games 那边踩过）。
cmd_run_installer() {
  local appid="$1" exe="$2" cwd="$3"
  [ -f "$exe" ] || die "找不到安装器：$exe"
  local p="$COMPAT/$appid"
  [ -d "$p" ] || die "游戏没有 prefix：${p}（游戏被删了？先 deck patches games 看看）"
  [ -d "$cwd" ] || die "找不到游戏目录：$cwd"
  local proton; proton="$(pick_proton)" || die "Deck 上没找到 Proton"
  export STEAM_COMPAT_CLIENT_INSTALL_PATH="$DECK_STEAM"
  export STEAM_COMPAT_DATA_PATH="$p"
  # ssh 进来时环境里既没有 DISPLAY 也没有 XAUTHORITY：硬写 DISPLAY=:0 会
  # "Authorization required"，向导窗口根本不开。从正在跑的桌面会话进程里读出来
  # —— 读法在公共库（deckkit_display_env）里：逐行 export，
  # **不用 eval**（值里有空格/引号/分号时 eval 会把陌生内容交给 shell 重新解析）。
  deckkit_display_env
  [ -n "${DISPLAY:-}" ] || die "拿不到 Deck 的桌面会话（DISPLAY）—— Deck 需要在桌面模式下。
       如果 ~/deckkit/bin/deck-lib 还没推上来（公共库缺失），先跑一次 deck patches install"
  xprop -root >/dev/null 2>&1 \
    || die "连不上 Deck 的桌面（DISPLAY=${DISPLAY} XAUTHORITY=${XAUTHORITY:-未设置}）—— 确认 Deck 在桌面模式，否则向导窗口只会干等"
  # Proton 会注入 Xalia（手柄导航的 .NET 组件），非 Steam 上下文里它会崩 →
  # 窗口永不出现（日志 "Unhandled exception in Xalia"）。我们直接关掉它。
  export PROTON_USE_XALIA=0
  # 中文补丁向导**满屏乱码**的根因：ssh 进来的环境 LANG 是空的（SteamOS 的
  # `locale` 是 POSIX），Wine 于是挑一个非 Unicode 代码页，中文全变方块/乱码。
  # 显式给 UTF-8：Steam 自己在桌面模式下就是跑在 UTF-8 上的。
  # LANG 用 zh_CN.UTF-8（很多安装器按它选简体中文界面）；系统没有这个 locale 时
  # 退回 C.UTF-8（同样是 UTF-8，界面语言是英文但不乱码）——都比乱码强。
  if locale -a 2>/dev/null | grep -qiE '^zh_CN\.(utf-?8|UTF-?8)$'; then
    export LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8
  else
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
  fi
  printf '  桌面     %s（XAUTHORITY %s）\n' "$DISPLAY" "${XAUTHORITY:-未设置}"
  printf '  Xalia    关闭（PROTON_USE_XALIA=0）\n'
  printf '  编码     %s（防中文乱码）\n' "${LC_ALL:-未设置}"
  printf '  proton   %s\n' "$proton"
  printf '  prefix   %s（游戏自己的）\n' "$p"
  printf '  起始目录 %s\n' "$cwd"
  # 以前这里是 `: > "$INSTALLER_LOG"`（直接清空）：上一次安装的现场就永久没了 ——
  # 装完才发现不对时无从回看。改成留一代（.1）+ 写一条启动锚点，
  # 好把「哪段输出来自哪一次」分开（proton 自己打的输出不带时间戳）。
  if [ -x "$DECK_LOG_TOOL" ]; then
    "$DECK_LOG_TOOL" --rotate patches-installer >/dev/null 2>&1 || true
    "$DECK_LOG_TOOL" patches-installer \
      "===== 跑安装器：$(basename "$exe")  游戏目录 $cwd  proton $proton =====" >/dev/null 2>&1 || true
  else
    : > "$INSTALLER_LOG"
  fi
  local rc=0
  ( cd "$cwd" && exec "${PROTONS_DIR}/${proton}/proton" run "$exe" ) >>"$INSTALLER_LOG" 2>&1 || rc=$?
  tail -8 "$INSTALLER_LOG" | sed 's/^/    /'
  return $rc
}

# 安装器跑完：把「这次被动过、内容真的变了」的文件写成 manifest.tsv
# 输出：<文件数>\t<字节数>（写给 Mac 侧读）
#
# **不能靠 mtime 找"刚写的文件"**（这条踩过，实测）：很多安装器/自解压器会把
# 文件时间戳设成**打包时的时间**（补丁作者那边），于是新写入的文件 mtime 反而
# 比"安装开始时刻"更早 —— `find -newermt @since` 一个都匹配不到。
# 实测 Some Game 3 官方汉化补丁：装进去 1469 个文件，
# 时间戳全是补丁打包时的 01:12~01:14，而安装动作发生在 03:03
# → find 只命中 2 个（游戏自己写的 debug.log / 存档），manifest 记成 0 条。
#
# 正确做法：**和安装前的快照整目录对比**（不管 mtime）。
#   · 快照里没有的路径（新增）        → 记
#   · 大小或 mtime 与快照不同（改过） → 记
#   · 完全一致（没被动过）            → 不记
# 这样"内容一模一样又被覆盖一遍"的情况仍然会被记（只看得到大小/mtime），
# 和原来行为一致；但不会再因为时间戳被改小而整批漏记。
# 参数 since 保留但只当兜底：万一快照丢了（空文件），退回按 mtime 找，
# 至少不至于一条不记。
cmd_manifest_from_install() {
  local patch="${1%/}" gdir="$2" before="$3" since="$4"
  local rel size mt old want md5 n=0 bytes=0 snap
  # 先写**临时文件**、最后 mv：以前是 `: > manifest.tsv` 再往里追加 ——
  # 中途失败 / Ctrl-C 会把旧清单**截成空**，而空清单在 state 里等于「状态未知」，
  # 看起来就像"没装上"（review 抓到）。
  local tmp; tmp="$(mktemp "$patch/.manifest.XXXXXX")" || die "建不了临时清单：$patch"
  local have_before=0
  [ -s "$before" ] && have_before=1

  # 安装后整目录快照。deckkit_snapshot 的退出码是诚实的：读不了就非 0 ——
  # 不能让"读失败"变成"一个文件都没变"（那正是把执行失败报成安装失败的老毛病）。
  if ! snap="$(deckkit_snapshot "$gdir")"; then
    rm -f "$tmp"
    die "安装后快照失败：读不了 ${gdir}（目录被删了？）"
  fi
  if [ "$have_before" != 1 ]; then
    # 快照丢了：退回按 mtime 过滤（可能漏记，至少给出结果并说明）
    printf '  警告：安装前快照缺失，只能按 mtime 找改动（可能漏记）\n' >&2
    snap="$(printf '%s\n' "$snap" | awk -F'\t' -v s="$since" '$3+0 >= s')"
  fi

  # 逐个和快照比（与 mtime 无关）：新增的记、大小或 mtime 变了的记、完全一致的不记
  while IFS=$'\t' read -r rel size mt; do
    [ -n "${rel:-}" ] || continue
    if [ "$have_before" = 1 ]; then
      old="$(REL="$rel" awk -F'\t' '$1==ENVIRON["REL"]{print $2"\t"$3; exit}' "$before" 2>/dev/null)"
      printf -v want '%s\t%s' "$size" "$mt"
      [ "$old" = "$want" ] && continue          # 没被动过
    fi
    md5="$(md5sum "$gdir/$rel" 2>/dev/null | cut -d' ' -f1)"
    [ -n "$md5" ] || continue
    printf '%s\t%s\t%s\n' "$rel" "$md5" "$size" >> "$tmp"
    n=$((n + 1)); bytes=$((bytes + size))
  done < <(printf '%s\n' "$snap")

  if ! mv -f "$tmp" "$patch/manifest.tsv"; then
    rm -f "$tmp"
    die "写 manifest 失败：$patch/manifest.tsv"
  fi
  printf '%s\t%s\n' "$n" "$bytes"
  return 0
}

# meta.tsv 里的 kind（installer / 空）。
# **读不到记录必须非 0**：Mac 侧靠这个码区分「这是安装器型补丁」和「记录坏了」
# （以前它恒返回 0，两种情形长得一样，坏记录会被当成普通文件包型）。
cmd_kind() {
  local patch="${1%/}"
  if [ ! -f "$patch/meta.tsv" ]; then
    printf '读不到补丁记录：%s\n' "$patch/meta.tsv" >&2
    return 1
  fi
  meta_get "$patch" kind
}

# 单个文件的状态（排查用）：<补丁目录> <相对路径> [期望 md5]
cmd_file_state() {
  local patch="${1%/}" rel="$2" md5="${3:-}"
  [ -n "$rel" ] || die "用法：patchctl.sh file-state <补丁目录> <相对路径> [期望 md5]"
  if [ -z "$md5" ]; then
    md5="$(REL="$rel" awk -F'\t' '$1==ENVIRON["REL"]{print $2; exit}' "$patch/manifest.tsv" 2>/dev/null)"
  fi
  file_state "$patch" "$rel" "$md5"
  printf '\n'
}

case "${1:-status}" in
  games)    cmd_games ;;
  list)     cmd_list ;;
  status)   shift; cmd_status "${1:-}" ;;
  state)    shift; cmd_state "${1%/}" ;;
  kind)     shift; cmd_kind "${1%/}" ;;
  mount)    shift; cmd_mount "${1%/}" ;;
  unmount)  shift; cmd_unmount "${1%/}" ;;
  find-sha) shift; cmd_find_sha "$1" ;;
  suggest)  cmd_suggest ;;
  resolve)  shift; cmd_resolve "${1%/}" ;;
  verify)   shift; cmd_verify "${1%/}" ;;
  remove)   shift; cmd_remove "${1%/}" "${2:-}" ;;
  menu)     cmd_menu ;;
  snapshot)        shift; cmd_snapshot "${1%/}" ;;
  fileinfo)        shift; cmd_fileinfo "$1" ;;
  file-state)      shift; cmd_file_state "$@" ;;
  run-installer)   shift; cmd_run_installer "$@" ;;
  manifest-from-install) shift; cmd_manifest_from_install "$@" ;;
  # usage 从**头部注释块**现算（以前写死 `sed -n '5,22p'`：头注释一改行号就错位）
  -h|--help|help|"") deckkit_usage_of "$0" ;;
  *) die "patchctl 不认识的子命令：$1" ;;
esac