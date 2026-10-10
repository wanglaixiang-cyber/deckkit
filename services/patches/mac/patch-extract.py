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
#  prepare 输出（TSV，按文件数降序）：<候选根>\t<文件数>\t<字节数>
#  候选根是补丁内部的相对目录（Setup Factory 是 %AppFolder%，Inno 是 app/，
#  NSIS/7z 直接解到根），Deck 侧再拿这些相对路径去和游戏目录比对。
# ============================================================
import glob
import os
import re
import shutil
import subprocess
import sys
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
    """返回 0 并把候选根打到 stdout；解包结果在 work/extract（输入是文件夹就不用解包）"""
    if os.path.isdir(src):
        log("  · 输入是文件夹：直接当解包结果（不解包）")
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
                # macOS 的 AppleDouble 陪衬文件（._xxx）不是补丁内容，别写进清单
                if f.startswith("._"):
                    try: os.remove(full)
                    except OSError: pass
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


def main():
    if len(sys.argv) < 3:
        print(__doc__ or "", file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    if cmd == "prepare":
        return cmd_prepare(sys.argv[2], sys.argv[3])
    if cmd == "manifest":
        return cmd_manifest(sys.argv[2], sys.argv[3], sys.argv[4])
    log("不认识的子命令：%s" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
