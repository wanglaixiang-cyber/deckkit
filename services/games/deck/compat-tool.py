#!/usr/bin/env python3
# ============================================================
#  deckkit / games —— 给某个 appid 设「强制使用某个 Proton」
#      compat-tool.py --check <appid>         查现在的映射
#      compat-tool.py --set   <appid> <工具名> 写入（自动备份 config.vdf）
#  工具名就是 Steam 内部的 compat 名：proton_11 / proton_10 / proton_experimental …
#  config.vdf 是**文本** KeyValues，往里插一段 CompatToolMapping 即可。
# ============================================================
import os, re, shutil, sys, time

P = os.path.expanduser("~/.steam/steam/config/config.vdf")


def main():
    a = sys.argv[1:]
    if len(a) >= 2 and a[0] == "--check":
        s = open(P, encoding="utf-8", errors="surrogateescape").read()
        m = re.search(r'"%s"\s*\{\s*"name"\s*"([^"]*)"' % a[1], s)
        print("appid %s → %s" % (a[1], m.group(1) if m else "（没有映射）"))
        return 0
    if len(a) >= 3 and a[0] == "--set":
        appid, tool = a[1], a[2]
        s = open(P, encoding="utf-8", errors="surrogateescape").read()
        if not re.search(r'"CompatToolMapping"', s):
            print("config.vdf 里没有 CompatToolMapping 段，跳过"); return 1
        if re.search(r'"%s"\s*\{' % appid, s):
            print("已存在映射，跳过"); return 0
        entry = ('\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n'
                 '\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"Priority"\t\t"250"\n\t\t\t\t\t}\n') % (appid, tool)
        i = s.index('"CompatToolMapping"'); j = s.index("{", i) + 1
        s = s[:j] + "\n" + entry + s[j:]
        shutil.copy2(P, P + ".deckkit-bak-" + time.strftime("%Y%m%d-%H%M%S"))
        open(P, "w", encoding="utf-8", errors="surrogateescape").write(s)
        print("已写入：appid %s → %s" % (appid, tool))
        return 0
    print(__doc__ or "", file=sys.stderr); return 2


if __name__ == "__main__":
    sys.exit(main())
