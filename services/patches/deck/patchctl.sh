#!/usr/bin/env bash
# ============================================================
#  deckkit / patches —— Deck 侧执行体
#
#  在 Deck 上跑，被 `deck patches ...` 通过 ssh 调起来。也可以直接在 Deck 上跑：
#
#    patchctl.sh games                    已装的游戏（Steam + deckkit 自己装的，两种都算）
#    patchctl.sh list                     补丁库里的补丁 + 当前挂载状态
#    patchctl.sh state <补丁目录>          单个补丁的状态（mounted/clean/partial/unknown）
#    patchctl.sh mount <补丁目录>          挂载：把补丁文件覆盖进游戏目录（不备份原文件）
#    patchctl.sh unmount <补丁目录>        卸载：只告诉你还原办法（原文件没备份）
#    patchctl.sh verify <补丁目录>         逐文件 md5 核对
#    patchctl.sh remove <补丁目录>         从库里删除（挂载中会拒绝）
#    patchctl.sh menu                     给菜单栏用的行
#
#  安装器型补丁（未实测）用的几条：
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
# ============================================================
set -uo pipefail

PATCH_ROOT="${PATCH_ROOT:-$HOME/deckkit/services/patches}"
STORE="$PATCH_ROOT/store"
STEAM_DIR="${STEAM_DIR:-$HOME/.steam/steam}"
COMPAT="$STEAM_DIR/steamapps/compatdata"
PROTONS_DIR="$STEAM_DIR/steamapps/common"
INSTALLER_LOG="$PATCH_ROOT/installer.log"

ok()   { printf '  \xe2\x9c\x93 %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
bad()  { printf '  \xe2\x9c\x97 %s\n' "$*"; }
dim()  { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ 游戏枚举 ---
# 库位置可能不止一个（SD 卡等），都能从 libraryfolders.vdf 里读到。
steam_libraries() {
  # ~/.steam/steam 与 ~/.local/share/Steam 是同一个目录（符号链接），
  # 不去重的话每个游戏会被数两遍 —— 匹配时会误判成「并列」。
  local vdf="$STEAM_DIR/steamapps/libraryfolders.vdf"
  { [ -f "$vdf" ] && sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf"
    printf '%s\n' "$STEAM_DIR"; } | while read -r p; do readlink -f "$p"; done | sort -u
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
    # 体积优先用记录里的（算一次 du 就够了；菜单栏会频繁调 cmd_games）
    sz="$(sed -n 's/^size=//p' "$d/meta.tsv" | head -1)"
    [ -n "$sz" ] || sz="$(sed -n 's/^prefix_size=//p' "$d/meta.tsv" | head -1)"
    [ -n "$sz" ] || sz="$(du -sh "$dir" 2>/dev/null | cut -f1)"
    printf '%s\t%s\t%s\t%s\n' "$appid" "$name" "$dir" "$sz"
  done
}

# 输出：appid \t 名字 \t 游戏目录 \t 大小（Steam 游戏 + deckkit 自己装的游戏）
cmd_games() {
  local lib acf id name dir full
  for lib in $(steam_libraries); do
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
      printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$full" "$(du -sh "$full" 2>/dev/null | cut -f1)"
    done
  done
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

# 补丁目录 → id（appid/slug）
patch_id() { printf '%s' "${1#$STORE/}"; }

meta_get() { sed -n "s/^$2=//p" "$1/meta.tsv" 2>/dev/null | head -1; }

game_dir_of() {
  local appid; appid="$(basename "$(dirname "$1")")"
  sed -n 's/^dir=//p' "$STORE/$appid/.game" 2>/dev/null | head -1
}
game_name_of() {
  local appid; appid="$(basename "$(dirname "$1")")"
  sed -n 's/^name=//p' "$STORE/$appid/.game" 2>/dev/null | head -1
}

# payload 里是否有大文件：状态用 md5 还是用大小（大 payload 上 md5 太慢）
use_hash() {
  local patch="$1" total=0 rel md5 size
  while IFS=$'\t' read -r rel md5 size; do
    [ -n "${size:-}" ] || continue
    total=$((total + size))
  done < "$patch/manifest.tsv"
  [ "$total" -le 536870912 ]      # 512 MiB 以内用 md5
}


# 补丁里的相对路径 → 游戏目录里的真实路径。
# 补丁是 Windows 世界的东西：它内部的分隔符可能是 \\，大小写也不敏感，
# 而 Deck 上大小写是敏感的。这里先按路径逐段找**真实存在**的名字，
# 找不到就按原样拼（挂载新文件时用），并把纠正结果记在 resolved.tsv 里。
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

# 一个文件现在处于什么状态：payload / original / absent / other
file_state() {
  # 现在**不备份**被替换的原文件（用户要求），所以只有三种判断：
  #   payload = 这个文件当前就是补丁版本
  #   absent  = 文件不存在
  #   other   = 既不是补丁版本（原版 / 被 Steam 还原 / 别的程序改过）
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
cmd_state() {
  local patch="$1" rel md5 size st n_pay=0 n_all=0 n_other=0 n_absent=0
  [ -f "$patch/manifest.tsv" ] || { printf 'unknown'; return 0; }
  # manifest 可能是空的（安装器型补丁：装完一个文件都没变）—— 那叫「未知」，
  # 不是「已挂载」（0 == 0 会误判成 mounted，然后 remove 就被自己的守卫拦住了）
  [ -s "$patch/manifest.tsv" ] || { printf 'unknown'; return 0; }
  while IFS=$'\t' read -r rel md5 size; do
    [ -n "${rel:-}" ] || continue
    n_all=$((n_all + 1))
    st="$(file_state "$patch" "$rel" "$md5")"
    case "$st" in
      payload) n_pay=$((n_pay + 1)) ;;
      absent)  n_absent=$((n_absent + 1)) ;;
      *)       n_other=$((n_other + 1)) ;;
    esac
  done < "$patch/manifest.tsv"
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

cmd_list() {
  local patch id st gname files
  [ -d "$STORE" ] || { printf '(补丁库是空的)\n'; return 0; }
  while read -r patch; do
    [ -n "$patch" ] || continue
    id="$(patch_id "$patch")"
    st="$(cmd_state "$patch")"
    gname="$(game_name_of "$patch")"
    files="$(wc -l < "$patch/manifest.tsv" 2>/dev/null | tr -d ' ')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$gname" "$(state_text "$st")" "$st" "$files"
  done < <(patch_dirs)
}

# 按 sha256 找库里的补丁（Mac 侧 mount-file 用：同一个 exe 只入库一次）
cmd_find_sha() {
  local want="$1" p sum
  while read -r p; do
    [ -n "$p" ] || continue
    sum="$(meta_get "$p" sha256)"
    [ -n "$sum" ] && [ "$sum" = "$want" ] && { patch_id "$p"; return 0; }
  done < <(patch_dirs)
  return 1
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

cmd_verify() {
  local patch="${1%/}" rel md5 size st pay=0 orig=0 other=0 absent=0
  while IFS=$'\t' read -r rel md5 size; do
    [ -n "${rel:-}" ] || continue
    st="$(file_state "$patch" "$rel" "$md5")"
    case "$st" in
      payload)  pay=$((pay + 1)) ;;
      original) orig=$((orig + 1)) ;;
      absent)   absent=$((absent + 1)) ;;
      *)        other=$((other + 1)); warn "与补丁不同：$rel" ;;
    esac
  done < "$patch/manifest.tsv"
  printf '  补丁版本 %s  非补丁版本 %s  缺失 %s\n' "$pay" "$((orig + other))" "$absent"
  [ "$pay" -gt 0 ] && [ "$other" = 0 ] && [ "$orig" = 0 ] && ok "校验：已完整挂载"
  [ "$pay" = 0 ] && ok "校验：当前不是补丁版本（未挂载 / 已被 Steam 还原）"
  return 0
}

cmd_remove() {
  local patch="${1%/}" force="${2:-}"
  # 先确认目录真的在：`rm -rf` 对不存在的路径是**静默成功**的 ——
  # 之前拿被 ~ 祸害过的路径来删，就报了个假的「已从补丁库删除」（实测）。
  [ -d "$patch" ] || die "找不到这个补丁目录：$patch"
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
  while read -r patch; do
    [ -n "$patch" ] || continue
    id="$(patch_id "$patch")"
    st="$(cmd_state "$patch")"
    gname="$(game_name_of "$patch")"
    files="$(wc -l < "$patch/manifest.tsv" 2>/dev/null | tr -d ' ')"
    if [ "$st" = "mounted" ]; then
      label="$(meta_get "$patch" name)  ✓ 已挂载"
      printf '%s\t%s\ttoggle %s\t点一下卸载（还原原始文件）· %s 个文件\n' "$gname" "$label" "$id" "$files"
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
  local patch id st gname
  printf '补丁库  %s\n' "$STORE"
  local n=0
  while read -r patch; do
    [ -n "$patch" ] || continue
    n=$((n + 1))
    id="$(patch_id "$patch")"
    st="$(cmd_state "$patch")"
    gname="$(game_name_of "$patch")"
    ok "$id  ${gname}  $(state_text "$st")"
    local srcinfo
    if [ -f "$patch/patch.exe" ]; then srcinfo="exe $(du -h "$patch/patch.exe" | cut -f1)"
    elif [ "$(meta_get "$patch" source)" = "dir" ]; then srcinfo="文件夹入库（无 exe）"
    else srcinfo="exe 缺失"; fi
    dim "$(wc -l < "$patch/manifest.tsv" | tr -d ' ') 个文件 · payload $([ -d "$patch/payload" ] && du -sh "$patch/payload" 2>/dev/null | cut -f1 || echo '不在 Deck（按配置不留）') · $srcinfo"
  done < <(patch_dirs)
  [ "$n" = 0 ] && warn "补丁库是空的（Mac 上：deck patches add <补丁.exe>）"
  return 0
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

# 目录快照：<相对路径>\t<大小>\t<mtime（%T@，带小数）>
cmd_snapshot() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -type f -printf '%P\t%s\t%T@\n' 2>/dev/null | sort
}

# 单个文件 → <大小>\t<mtime 秒>\t<md5>
cmd_fileinfo() {
  local f="$1"
  [ -f "$f" ] || return 0
  printf '%s\t%s\t%s\n' "$(stat -c%s "$f" 2>/dev/null)" \
    "$(stat -c%Y "$f" 2>/dev/null)" "$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"
}

cmd_protons() {
  local d
  for d in "$PROTONS_DIR"/Proton*; do
    [ -d "$d" ] || continue
    [ -x "$d/proton" ] && basename "$d"
  done
}

pick_proton() {
  local p
  p="$(cmd_protons | grep -E '^Proton [0-9]' | sort -t' ' -k2 -V | tail -1)"
  [ -n "$p" ] || p="$(cmd_protons | grep -i experimental | head -1)"
  [ -n "$p" ] || p="$(cmd_protons | head -1)"
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

# 用游戏自己的 prefix 拉起补丁安装器。输出写日志文件，不继承 ssh 管道
# （proton 的子进程抓着管道不放会让 ssh 一直不返回，games 那边踩过）。
cmd_run_installer() {
  local appid="$1" exe="$2" cwd="$3"
  [ -f "$exe" ] || die "找不到安装器：$exe"
  local p="$COMPAT/$appid"
  [ -d "$p" ] || die "游戏没有 prefix：${p}（游戏被删了？先 deck patches games 看看）"
  [ -d "$cwd" ] || die "找不到游戏目录：$cwd"
  local proton; proton="$(pick_proton)" || die "Deck 上没找到 Proton"
  export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_DIR"
  export STEAM_COMPAT_DATA_PATH="$p"
  # ssh 进来时环境里既没有 DISPLAY 也没有 XAUTHORITY：硬写 DISPLAY=:0 会
  # "Authorization required"，向导窗口根本不开。从正在跑的桌面会话进程里读出来。
  if [ -z "${DISPLAY:-}" ] || [ -z "${XAUTHORITY:-}" ]; then
    local sp="" n
    for n in plasmashell kwin_wayland steam; do
      sp="$(pgrep -x "$n" 2>/dev/null | head -1)"
      [ -n "$sp" ] && break
    done
    if [ -n "$sp" ] && [ -r "/proc/$sp/environ" ]; then
      eval "$(tr '\0' '\n' < "/proc/$sp/environ" \
        | grep -E '^(DISPLAY|XAUTHORITY|WAYLAND_DISPLAY)=' | sed 's/^/export /')"
    fi
  fi
  [ -n "${DISPLAY:-}" ] || die "拿不到 Deck 的桌面会话（DISPLAY）—— Deck 需要在桌面模式下"
  xprop -root >/dev/null 2>&1 \
    || die "连不上 Deck 的桌面（DISPLAY=${DISPLAY} XAUTHORITY=${XAUTHORITY:-未设置}）—— 确认 Deck 在桌面模式，否则向导窗口只会干等"
  # Proton 会注入 Xalia（手柄导航的 .NET 组件），非 Steam 上下文里它会崩 →
  # 窗口永不出现（日志 "Unhandled exception in Xalia"）。我们直接关掉它。
  export PROTON_USE_XALIA=0
  printf '  桌面     %s（XAUTHORITY %s）\n' "$DISPLAY" "${XAUTHORITY:-未设置}"
  printf '  Xalia    关闭（PROTON_USE_XALIA=0）\n'
  printf '  proton   %s\n' "$proton"
  printf '  prefix   %s（游戏自己的）\n' "$p"
  printf '  起始目录 %s\n' "$cwd"
  : > "$INSTALLER_LOG"
  local rc=0
  ( cd "$cwd" && exec "${PROTONS_DIR}/${proton}/proton" run "$exe" ) >>"$INSTALLER_LOG" 2>&1 || rc=$?
  tail -8 "$INSTALLER_LOG" | sed 's/^/    /'
  return $rc
}

# 安装器跑完：把「这次被动过、内容真的变了」的文件写成 manifest.tsv
# 输出：<文件数>\t<字节数>（写给 Mac 侧读）
# 为什么还要比一次大小+mtime：安装器经常把补丁里**和原文件一样**的内容再覆盖一遍，
# 那种文件如果也记进 manifest，Steam 校验还原之后状态会永远停在「已挂载」。
cmd_manifest_from_install() {
  local patch="${1%/}" gdir="$2" before="$3" since="$4"
  local rel size mt old want md5 n=0 bytes=0
  : > "$patch/manifest.tsv"
  while IFS=$'\t' read -r rel size mt; do
    [ -n "${rel:-}" ] || continue
    [ -f "$gdir/$rel" ] || continue
    old="$(REL="$rel" awk -F'\t' '$1==ENVIRON["REL"]{print $2"\t"$3; exit}' "$before" 2>/dev/null)"
    printf -v want '%s\t%s' "$size" "$mt"
    [ "$old" = "$want" ] && continue
    md5="$(md5sum "$gdir/$rel" 2>/dev/null | cut -d' ' -f1)"
    [ -n "$md5" ] || continue
    printf '%s\t%s\t%s\n' "$rel" "$md5" "$size" >> "$patch/manifest.tsv"
    n=$((n + 1)); bytes=$((bytes + size))
  done < <(find "$gdir" -type f -newermt "@$since" -printf '%P\t%s\t%T@\n' 2>/dev/null | sort)
  printf '%s\t%s\n' "$n" "$bytes"
  return 0
}

case "${1:-status}" in
  games)    cmd_games ;;
  list)     cmd_list ;;
  status)   cmd_status ;;
  state)    shift; cmd_state "${1%/}" ;;
  kind)     shift; meta_get "${1%/}" kind ;;
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
  run-installer)   shift; cmd_run_installer "$@" ;;
  manifest-from-install) shift; cmd_manifest_from_install "$@" ;;
  -h|--help|help|"") sed -n '5,22p' "$0" | sed 's/^# \?//' ;;
  *) die "patchctl 不认识的子命令：$1" ;;
esac
