#!/usr/bin/env python3
"""NFD → NFC 文件名规范化（Deck 侧运行）。

为什么需要：macOS 的文件系统把名字存成 **NFD**（`ゾ` = U+30BD `ソ` + U+3099 组合浊点），
而游戏自己的数据（`data/*.json`、脚本、配置）里写的是 **NFC**（U+30BE `ゾ`）。
用 macOS 当"中转站"拷过来的游戏就会出现「数据里 NFC、磁盘上 NFD」→ 引擎按数据拼
路径时 404。实测：RPG Maker MZ 的 `Some Game 2BGM/A.D.ENDによるクラシック.ogg_`
在磁盘上叫 `Some Game 2BGM/…`，游戏直接停在 "Failed to load"。
（ASCII 名字不受影响，所以这类问题只挑日文/带浊点的名字犯，很难一眼看出来。）

用法：
    nfc-names.py <目录> [--check] [--quiet] [--undo <表>]
        --check        只数有多少个名字不规范，不改
        --quiet        只打印数字（给脚本用）
        --undo <表>    按之前写出的表把 NFC 还原回 NFD

从最深的层往上改（先文件后目录），否则父目录一改名，之前记下的子路径就失效了。
只改名字形式，不动文件内容；同名冲突会跳过并报出来。
"""
import os
import sys
import unicodedata


def walk_bad(root):
    out = []
    for dirpath, dirs, files in os.walk(root):
        for name in dirs + files:
            if not unicodedata.is_normalized("NFC", name):
                out.append(os.path.join(dirpath, name))
    return out


def normalize(root, undo_path, quiet):
    bad = walk_bad(root)
    bad.sort(key=lambda p: p.count(os.sep), reverse=True)   # 深的先改
    done, skipped = [], []
    for src in bad:
        dst = os.path.join(os.path.dirname(src),
                           unicodedata.normalize("NFC", os.path.basename(src)))
        if src == dst:
            continue
        if os.path.exists(dst):
            skipped.append(os.path.relpath(dst, root))
            continue
        os.rename(src, dst)
        done.append((os.path.relpath(src, root), os.path.relpath(dst, root)))
    if undo_path:
        with open(undo_path, "w", encoding="utf-8") as f:
            for a, b in done:
                f.write(f"{b}\t{a}\n")        # 反向：NFC → NFD
    if quiet:
        print(len(done))
    else:
        print(f"NFD→NFC 改名 {len(done)} 个，跳过 {len(skipped)} 个（NFC 版本已存在）")
        for s in skipped[:5]:
            print(f"  跳过 {s}")
    return len(done)


def undo(undo_path, quiet):
    n = 0
    with open(undo_path, encoding="utf-8") as f:
        rows = [line.rstrip("\n").split("\t") for line in f if line.strip()]
    rows.sort(key=lambda r: r[0].count(os.sep), reverse=True)
    for cur, orig in rows:
        if os.path.exists(cur) and not os.path.exists(orig):
            os.rename(cur, orig)
            n += 1
    if quiet:
        print(n)
    else:
        print(f"已还原 {n} 个名字（NFC→NFD）")
    return n


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    root, check, quiet, undo_path = argv[1], False, False, ""
    i = 2
    while i < len(argv):
        if argv[i] == "--check":
            check = True
        elif argv[i] == "--quiet":
            quiet = True
        elif argv[i] == "--undo":
            i += 1
            undo_path = argv[i]
        i += 1
    if undo_path:
        undo(undo_path, quiet)
        return 0
    if check:
        n = len(walk_bad(root))
        print(n if quiet else f"NFD 名字 {n} 个")
        return 0
    normalize(root, "/tmp/deckkit-nfc-undo.tsv", quiet)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
