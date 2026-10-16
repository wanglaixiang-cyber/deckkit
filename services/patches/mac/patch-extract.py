#!/usr/bin/env python3
# ============================================================
#  deckkit / patches —— Mac 侧解包助手
#
#  补丁 exe 有两种：一种是真安装器（要点下一步、写注册表），一种是
#  "文件包 + 自解压壳"。这个脚本只对付后者：把里面的文件原样解出来。
#
#    patch-extract.py prepare  <exe> <workdir>        解包 + 列出候选根
#    patch-extract.py manifest <workdir> <root> <out> 写出 manifest.tsv
#
#  prepare 输出（TSV）：
#    第 1 行   BASE\t<解包根>          ← Mac 侧拿它当 src_root（可能是**用户那个目录**）
#    第 2 行起 <候选根>\t<文件数>\t<字节数>（按文件数降序）
#  候选根是补丁内部的相对目录（Setup Factory 是 %AppFolder%，Inno 是 app/，
#  NSIS/7z 直接解到根），Deck 侧再拿这些相对路径去和游戏目录比对。
#
#  **用户给的目录只读**：输入是文件夹时，凡是要改名的（Windows 反斜杠路径）
#  都在 work 里的副本上做（硬链过去，不占额外空间）。这个脚本只读用户目录、
#  只读补丁 exe —— 任何改写都发生在 work/ 里。
# ============================================================
import glob
import os
import re
import shutil
import struct
import subprocess
import sys
import math
import hashlib

CANDIDATE_ROOTS = ["%AppFolder%", "$INSTDIR", "app", "."]


def log(*a):
    print(*a, file=sys.stderr)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def sfextract_cli():
    """找 sfextract 命令行；没有就退回 python -c 调它的 main()。"""
    p = shutil.which("sfextract")
    if p:
        return [p]
    for pat in (
        os.path.expanduser("~/Library/Python/*/bin/sfextract"),
        "/opt/homebrew/bin/sfextract",
        "/usr/local/bin/sfextract",
    ):
        hits = sorted(glob.glob(pat))
        if hits:
            return [hits[-1]]
    try:
        import sfextract  # noqa: F401
    except ImportError:
        return None
    return [sys.executable, "-c",
            "import sys; from sfextract.main import main; sys.exit(main())"]


def extract(exe, out):
    """返回用到的解包器名字；全失败返回 None。"""
    os.makedirs(out, exist_ok=True)

    cli = sfextract_cli()
    if cli:
        r = run(cli + ["-o", out, exe])
        if r.returncode == 0 and any(os.scandir(out)):
            log("  · 用 sfextract 解包（Setup Factory）")
            return "sfextract"
        log("  · sfextract 不认这个文件，换下一个解包器")

    if shutil.which("innoextract"):
        r = run(["innoextract", "-s", "-d", out, exe])
        if r.returncode == 0 and any(os.scandir(out)):
            log("  · 用 innoextract 解包（Inno Setup）")
            return "innoextract"
        log("  · innoextract 不认这个文件，换下一个解包器")

    z = shutil.which("7zz") or shutil.which("7z")
    if z:
        r = run([z, "x", "-y", "-o" + out, exe])
        if r.returncode == 0:
            log("  · 用 7z 解包")
            return "7z"
        log("  · 7z 也解不开：%s" % (r.stderr or "").strip()[:200])

    return None


def count_files(root):
    n = 0
    total = 0
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            n += 1
            try:
                total += os.path.getsize(os.path.join(dirpath, f))
            except OSError:
                pass
    return n, total


def collect_candidates(base):
    """候选 payload 根：已知的安装器变量目录 + 顶层子目录 + 自己。

    exe 里通常有 %AppFolder% 这种标记层；**纯文件夹没有标记**，
    所以把顶层子目录也当候选，靠「哪个根命中的游戏文件最多」来定。
    """
    names = list(CANDIDATE_ROOTS)
    try:
        for name in sorted(os.listdir(base)):
            if os.path.isdir(os.path.join(base, name)):
                names.append(name)
    except OSError:
        pass
    names.append(".")
    rows, seen = [], set()
    for name in names:
        if name in seen:
            continue
        seen.add(name)
        p = base if name == "." else os.path.join(base, name)
        if not os.path.isdir(p):
            continue
        n, total = count_files(p)
        if n:
            rows.append((name, n, total))
    rows.sort(key=lambda r: -r[1])
    return rows


def has_backslash_names(root):
    """树里有没有「反斜杠当文件名」的条目（有才需要复制出来改名）。"""
    for dirpath, dirs, files in os.walk(root):
        for name in list(files) + list(dirs):
            if "\\" in name:
                return True
    return False


def copytree_hardlink(src, dst):
    """把 src 树复制到 dst：先试硬链（同文件系统上零拷贝），失败退回 copy2。

    用来在**不动用户目录**的前提下做改名/整理 —— 用户给的补丁文件夹可能几十 GB，
    硬链只是多一份目录项。
    """
    os.makedirs(dst, exist_ok=True)
    for dirpath, _dirs, files in os.walk(src):
        rel = os.path.relpath(dirpath, src)
        target_dir = dst if rel == "." else os.path.join(dst, rel)
        os.makedirs(target_dir, exist_ok=True)
        for f in files:
            s = os.path.join(dirpath, f)
            d = os.path.join(target_dir, f)
            if os.path.lexists(d):
                continue
            try:
                os.link(s, d)
            except OSError:
                try:
                    shutil.copy2(s, d, follow_symlinks=False)
                except OSError:
                    pass


def materialize_backslashes(root):
    """Windows 路径分隔符：有些归档把 `Audio\\BGM\\x.ogg` 存成**一个文件名**。
    macOS 照做，而 Deck 上那应该是目录 —— 这里统一落地成真正的目录层级。"""
    moved = 0
    for dirpath, dirs, files in list(os.walk(root, topdown=False)):
        for f in list(files):
            if "\\" not in f:
                continue
            parts = [x for x in f.split("\\") if x]
            if not parts:
                continue
            dst = os.path.join(dirpath, *parts)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            os.replace(os.path.join(dirpath, f), dst)
            moved += 1
        for d in list(dirs):
            if "\\" not in d:
                continue
            parts = [x for x in d.split("\\") if x]
            if not parts:
                continue
            dst = os.path.join(dirpath, *parts)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if not os.path.exists(dst):
                os.replace(os.path.join(dirpath, d), dst)
                moved += 1
    if moved:
        log("  · 把 %d 个带反斜杠的 Windows 路径落地成目录" % moved)
    return moved


def cmd_prepare(src, work):
    """返回 0 并把「BASE<tab>解包根」+ 候选根打到 stdout。

    解包结果在 work/extract；输入是文件夹时解包根可能是 src 本身（只读），
    也可能是 work/extract 里的副本（需要改名时，见上面）。
    """
    if os.path.isdir(src):
        # 用户给的目录**只读**：要改名（Windows 反斜杠路径）时先硬链到 work 里再动。
        # 以前这里直接把 src 当 base 往下传，materialize_backslashes 就地
        # os.replace / os.remove —— 会覆盖/删掉**用户目录里的文件**（review 抓到）。
        if has_backslash_names(src):
            log("  · 输入是文件夹，里面有「反斜杠当文件名」的条目：")
            log("    先硬链到工作目录再改名（用户目录只读，不动它）")
            base = os.path.join(work, "extract")
            copytree_hardlink(src, base)
        else:
            log("  · 输入是文件夹：直接当解包结果（不解包、不改名，只读）")
            base = src
    else:
        base = os.path.join(work, "extract")
        kind = extract(src, base)
        if kind is None:
            log("")
            log("解不开这个文件。它可能是「真安装器」而不是文件包，装了这些再试：")
            log("  Setup Factory : pip3 install --user sfextract")
            log("  Inno Setup    : brew install innoextract")
            log("  压缩包/NSIS   : brew install sevenzip")
            return 1
    # 有些归档把 Windows 路径当成**文件名**存（`Audio\BGM\x.ogg` 是一个文件名）。
    # 必须落地成真正的目录层级，否则会平铺在游戏根目录、匹配不到几个文件。
    materialize_backslashes(base)

    # 第一行告诉调用方真正的解包根（可能是 work/extract 里的副本，也可能是 src 本身）
    print("BASE\t%s" % base)
    rows = collect_candidates(base)
    for name, n, total in rows:
        print("%s\t%d\t%d" % (name, n, total))
    if not rows:
        log("里没有文件")
        return 1
    return 0


def cmd_manifest(work, root, outfile):
    """work 是解包根（或用户给的文件夹），root 是其中的候选根"""
    base = work if root == "." else os.path.join(work, root)
    if not os.path.isdir(base):
        log("没有这个候选根：%s" % base)
        return 1
    n = 0
    with open(outfile, "w", encoding="utf-8") as fh:
        for dirpath, _dirs, files in sorted(os.walk(base)):
            for f in sorted(files):
                full = os.path.join(dirpath, f)
                if os.path.islink(full):
                    continue
                # macOS 的 AppleDouble 陪衬文件（._xxx）不是补丁内容：**跳过，不删**。
                # 输入可能是用户自己的目录（review 抓到过这里 os.remove 动用户文件），
                # 这个脚本一律不写不删源目录里的东西。
                if f.startswith("._"):
                    continue
                rel = os.path.relpath(full, base)
                h = hashlib.md5()
                with open(full, "rb") as src:
                    for chunk in iter(lambda: src.read(1 << 20), b""):
                        h.update(chunk)
                fh.write("%s\t%s\t%d\n" % (rel, h.hexdigest(), os.path.getsize(full)))
                n += 1
    log("  · manifest：%d 个文件" % n)
    return 0


def _pe_info(path):
    """读 PE 头：返回 (区段结束偏移, 文件大小) 或 None。用于判断有没有附加数据。"""
    try:
        with open(path, "rb") as f:
            head = f.read(0x400)
            if len(head) < 0x40 or head[:2] != b"MZ":
                return None
            pe = struct.unpack_from("<I", head, 0x3c)[0]
            if pe + 24 > len(head):
                return None
            if head[pe:pe + 4] != b"PE\0\0":
                return None
            nsec = struct.unpack_from("<H", head, pe + 6)[0]
            optsz = struct.unpack_from("<H", head, pe + 20)[0]
            end = 0
            f.seek(0)
            for i in range(nsec):
                off = pe + 24 + optsz + i * 40
                f.seek(off + 16)
                rsize = struct.unpack("<I", f.read(4))[0]
                f.seek(off + 20)
                raw = struct.unpack("<I", f.read(4))[0]
                end = max(end, raw + rsize)
            return end, os.path.getsize(path)
    except (OSError, struct.error):
        return None


def _entropy(path, off, n=65536):
    """算一段的熵。> 7.9 基本就是加密/压缩数据（不是代码也不是明文资源）。"""
    try:
        with open(path, "rb") as f:
            f.seek(off)
            d = f.read(n)
        if not d:
            return 0.0
        cnt = [0] * 256
        for b in d:
            cnt[b] += 1
        ent = 0.0
        for c in cnt:
            if c:
                p = c / len(d)
                ent -= p * math.log2(p)
        return ent
    except OSError:
        return 0.0


# 真安装器的指纹（在文件头 2MB 里找就够 —— 这些都出现在 PE 资源/代码段）
INSTALLER_SIGS = [
    ("Inno Setup", [b"Inno Setup Setup Data", b"InnoSetupLdr", b"JR.Inno.Setup"]),
    ("NSIS", [b"NullsoftInst", b"Nullsoft Install System", b"NSIS Error"]),
    ("InstallShield", [b"InstallShield", b"ISSetupStream"]),
    ("Setup Factory", [b"Setup Factory", b"Indigo Rose"]),
    ("Wise", [b"Wise Installation"]),
    ("MSI", [b"Microsoft Installer"]),
]


def cmd_classify(exe):
    """判断这个 exe 属于哪一类，把结论和**依据**打到 stdout（TSV：kind \\t 说明）。

    kind:
      installer  有安装器指纹（Inno/NSIS/...）→ 能解包就先解，解不动才走 --installer
      selfextract 没指纹，但有巨大的高熵 overlay + 极小代码段 → 私有自解压器，
                  解包器不认识它，只能跑起来（--installer）
      sfx_plain  有 overlay 但熵不高 → 可能是普通自解压（7z 之类），先试解包
      plain      没有 overlay，就是个普通 exe（多半是游戏主程序，不是补丁）
      not_pe     不是 PE（zip/7z/文件夹等，直接走解包）
    """
    if not os.path.isfile(exe):
        return 1
    with open(exe, "rb") as f:
        head = f.read(2 * 1024 * 1024)
    if head[:2] != b"MZ":
        print("not_pe\t不是 Windows 可执行文件（压缩包/其它），按文件包处理")
        return 0

    for name, sigs in INSTALLER_SIGS:
        for s in sigs:
            if s in head:
                print("installer\t有 %s 指纹" % name)
                return 0

    pe = _pe_info(exe)
    if not pe:
        print("plain\tPE 头读不出来，先试解包")
        return 0
    end, total = pe
    overlay = total - end
    # 代码本体很小、尾巴极大 → 内容全在附加数据里
    if overlay > 8 * 1024 * 1024 and end < 4 * 1024 * 1024:
        ent = _entropy(exe, end)
        if ent > 7.9:
            print("selfextract\t代码段仅 %.1fMB，尾部附加 %.1fMB 且熵 %.2f（加密/压缩），"
                  "解包器不认 —— 只能跑起来装" % (end / 1048576, overlay / 1048576, ent))
        else:
            print("sfx_plain\t代码段 %.1fMB，尾部附加 %.1fMB，熵 %.2f —— 可能是普通自解压，先试解包"
                  % (end / 1048576, overlay / 1048576, ent))
        return 0

    if overlay > 1024 * 1024:
        print("sfx_plain\t尾部有 %.1fMB 附加数据，先试解包" % (overlay / 1048576))
        return 0

    print("plain\t没有明显附加数据，就是个普通 exe —— 先试解包（也可能根本不是补丁）")
    return 0


def main():
    if len(sys.argv) < 3:
        print(__doc__ or "", file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    if cmd == "prepare":
        return cmd_prepare(sys.argv[2], sys.argv[3])
    if cmd == "manifest":
        return cmd_manifest(sys.argv[2], sys.argv[3], sys.argv[4])
    if cmd == "classify":
        return cmd_classify(sys.argv[2])
    log("不认识的子命令：%s" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
