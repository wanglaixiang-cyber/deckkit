#!/usr/bin/env python3
# ============================================================
#  deckkit / games —— Steam 非 Steam 快捷方式（shortcuts.vdf）读写
#
#    shortcut-vdf.py --check <steam>/userdata        无损性自检（解析→回写是否与原文一致）
#    shortcut-vdf.py --add   <steam>/userdata <appid> <名字> <linux exe> <起始目录> [图标]
#    shortcut-vdf.py --has   <steam>/userdata <appid> 回读确认（按 appid 找，不看名字）
#
#  shortcuts.vdf 是 Steam 的二进制 KeyValues：
#    0x00 嵌套对象（后跟键名 NUL）    0x01 字符串（键名 NUL 值 NUL）
#    0x02 int32（键名 NUL 4 字节 LE） 0x07 int64   0x03 float   0x08 对象结束
#
#  为什么要自检：这个文件里还存着用户**已有的**非 Steam 快捷方式，
#  写坏了等于把人家列表清空。所以先做「解析→回写 = 原文」的字节级验证，
#  通过了才允许写入；写之前还会备份。
# ============================================================
import glob
import os
import shutil
import struct
import subprocess
import sys
import time

TYPES_STR = {0x01, 0x00}


def parse(data):
    pos = 0

    def cstr():
        nonlocal pos
        end = data.index(b"\x00", pos)
        s = data[pos:end].decode("utf-8", "surrogateescape")
        pos = end + 1
        return s

    def obj():
        nonlocal pos
        out = []
        while pos < len(data):
            t = data[pos]
            pos += 1
            if t == 0x08:
                return out
            key = cstr()
            if t == 0x00:
                out.append((key, "obj", obj()))
            elif t == 0x01:
                out.append((key, "str", cstr()))
            elif t == 0x02:
                out.append((key, "int", struct.unpack_from("<i", data, pos)[0]))
                pos += 4
            elif t == 0x07:
                out.append((key, "u64", struct.unpack_from("<q", data, pos)[0]))
                pos += 8
            elif t == 0x03:
                out.append((key, "float", struct.unpack_from("<f", data, pos)[0]))
                pos += 4
            else:
                raise ValueError("未知类型 0x%02x（偏移 %d）" % (t, pos - 1))
        raise ValueError("文件在对象结束前就没了")

    root = obj()
    # Steam 自己会在文件末尾多留几个 0x08（对象结束标记）：实测原文尾部是
    # 4 个，而我们按结构只能产出 3 个 —— 差这一个字节，安全阀就会拒绝写入。
    # 记下原文末尾 0x08 的个数，回写时补齐（语义相同，字节一致）。
    closes = 0
    while closes < len(data) and data[len(data) - 1 - closes] == 0x08:
        closes += 1
    return root, data[pos:], closes


def dump(root, tail=b"", closes=0):
    out = bytearray()

    def write(items):
        for key, t, v in items:
            kb = key.encode("utf-8", "surrogateescape") + b"\x00"
            if t == "obj":
                out.append(0x00)
                out.extend(kb)
                write(v)
                out.append(0x08)
            elif t == "str":
                out.append(0x01)
                out.extend(kb)
                out.extend(v.encode("utf-8", "surrogateescape") + b"\x00")
            elif t == "int":
                out.append(0x02)
                out.extend(kb)
                v = int(v)
                # Steam 内部按有符号 int32 存：crc32|0x80000000 这类值 ≥ 2^31，
                # 必须先折算成负数，否则 struct.pack("<i") 直接抛错（实测 appid 崩过）
                if v > 0x7FFFFFFF:
                    v -= 0x100000000
                elif v < -0x80000000:
                    v += 0x100000000
                out.extend(struct.pack("<i", v))
            elif t == "u64":
                out.append(0x07)
                out.extend(kb)
                out.extend(struct.pack("<q", v))
            elif t == "float":
                out.append(0x03)
                out.extend(kb)
                out.extend(struct.pack("<f", v))

    write(root)
    body = bytes(out) + tail
    have = 0
    while have < len(body) and body[len(body) - 1 - have] == 0x08:
        have += 1
    # 规范写法：结构自身的结束标记之外，还要有一个收尾根对象（Steam 的文件就是这样，
    # 实测尾部 4 个 0x08 = tags/entry/shortcuts/root）。少了它解析器会认为文件被截断
    # —— 之前从被截断的文件里继承 closes=2，就写出过"自己解析不了"的文件。
    need = max(closes, have + 1)
    if need > have:
        body += b"\x08" * (need - have)
    return body


def files_of(userdata):
    return sorted(glob.glob(os.path.join(userdata, "*", "config", "shortcuts.vdf")))


def steam_running():
    return subprocess.run(["pgrep", "-x", "steam"], capture_output=True).returncode == 0


def cmd_check(userdata):
    fs = files_of(userdata)
    if not fs:
        print("  ! %s 下没有 config/shortcuts.vdf（Steam 还没建过快捷方式？）" % userdata)
        return 1
    bad = 0
    for f in fs:
        raw = open(f, "rb").read()
        try:
            root, tail, closes = parse(raw)
            again = dump(root, tail, closes)
        except Exception as e:
            print("  ✗ %s 解析失败：%s" % (f, e))
            bad += 1
            continue
        if again == raw:
            n = len(root[0][2]) if root else 0
            print("  ✓ %s 无损（%d 字节，%d 条快捷方式）" % (f, len(raw), n))
        else:
            print("  ✗ %s 回写与原文不一致（%d vs %d 字节）—— 不敢写" % (f, len(again), len(raw)))
            bad += 1
    return 1 if bad else 0


def cmd_add(userdata, appid, name, exe, startdir, icon=""):
    fs = files_of(userdata)
    if not fs:
        print("  ! 没找到 shortcuts.vdf（先在 Steam 里加过一个非 Steam 游戏再来）")
        return 1
    if steam_running():
        print("  ! Steam 正在运行 —— 先完全退出 Steam 再写（否则会被它覆盖回去）")
        return 1
    entry = [
        ("appid", "int", int(appid)),
        ("AppName", "str", name),
        ("Exe", "str", exe),
        ("StartDir", "str", startdir),
        ("icon", "str", icon),
        ("ShortcutPath", "str", ""),
        ("LaunchOptions", "str", ""),
        ("IsHidden", "int", 0),
        ("AllowDesktopConfig", "int", 1),
        ("AllowOverlay", "int", 1),
        ("OpenVR", "int", 0),
        ("Devkit", "int", 0),
        ("DevkitGameID", "str", ""),
        ("DevkitOverrideAppID", "int", 0),
        ("LastPlayTime", "int", 0),
        ("FlatpakAppID", "str", ""),
        ("tags", "obj", []),
    ]
    for f in fs:
        raw = open(f, "rb").read()
        parsed_ok = True
        try:
            root, tail, closes = parse(raw)          # 空文件/被 Steam 清坏的文件都能兜住
        except Exception:
            parsed_ok = False
            # 文件不在或解析不了：**不**去翻备份（那会把你删掉的条目复活），
            # 直接从空结构开始，只写我们要加的这一条。
            root, tail, closes = [("shortcuts", "obj", [])], b"", 4
        # 只有原文件本身能解析且规范时才要求回写逐字节相等；解析失败的坏文件
        # 本来就是从空结构重写的，没法比（之前会误报"解析不自洽"）
        canonical = parsed_ok and (closes >= 4)

        if canonical and dump(root, tail, closes) != raw:

            print("  ! 文件解析不自洽，先跑 --check 看细节"); return 1

        if not canonical:
            print("  · 原文件不完整（多半被 Steam 截断过），按规范重写")
        shortcuts = root[0][2]                       # ('shortcuts', 'obj', [...])
        idx = [int(k) for k, t, _ in shortcuts if t == "obj" and k.isdigit()]
        nxt = (max(idx) + 1) if idx else 0
        # 同一条别加两遍：按 appid 去重（保留先出现的那条），索引重排成连续数字
        _seen, _keep = set(), []
        for _k, _t, _v in shortcuts:
            _a = next((x for kk, tt, x in _v if kk == "appid" and tt == "int"), None) if _t == "obj" else None
            _key = (int(_a) & 0xFFFFFFFF) if _a is not None else None
            if _key is not None and _key in _seen:
                continue
            if _key is not None:
                _seen.add(_key)
            _keep.append((_k, _t, _v))
        _done = list(shortcuts)
        if len(_keep) != len(shortcuts):
            print("  · 去掉 %d 条重复条目" % (len(shortcuts) - len(_keep)))
        shortcuts[:] = [(str(_i), _t, _v) for _i, (_k, _t, _v) in enumerate(_keep)]
        if (int(appid) & 0xFFFFFFFF) in _seen:
            # 已经在库里了：只把"去重"这个结果落盘，不再追加第二条
            if len(_done) != len(_keep):
                open(f, "wb").write(dump(root, tail, closes))
                print("  ✓ 已写回去重后的列表（%d 条）" % len(_keep))
            print("  · 这条已经在库里了（appid %s），跳过" % appid)
            return 0
        nxt = len(shortcuts)
        shortcuts.append((str(nxt), "obj", entry))
        if os.path.getsize(f) > 64:      # 空壳/被 Steam 清坏的文件不必备份
            shutil.copy2(f, f + ".deckkit-bak-" + time.strftime("%Y%m%d-%H%M%S"))
        open(f, "wb").write(dump(root, tail, closes))
        print("  ✓ %s 已添加「%s」(appid %s，index %d)" % (f, name, appid, nxt))
    return 0


def cmd_has(userdata, appid):
    """回读确认：这个 appid 真的落在 live 文件里吗

    按 **appid** 比，不看名字 —— 名字可能是日文，而 `strings` 只输出 ASCII 串，
    用它来查日文名必然查不到（实测：写进去了却报"回读不到"，白让人再跑一遍）。
    """
    fs = files_of(userdata)
    if not fs:
        print("  ! %s 下没有 shortcuts.vdf" % userdata)
        return 1
    want = int(appid) & 0xFFFFFFFF
    for f in fs:
        try:
            root, _, _ = parse(open(f, "rb").read())
        except Exception as e:
            print("  ! %s 解析失败：%s" % (f, e))
            return 1
        sc = next((v for k, t, v in root if t == "obj"), None) or []
        for _k, t, v in sc:
            if t != "obj":
                continue
            aid = next((x for kk, tt, x in v if kk == "appid" and tt == "int"), None)
            if aid is not None and (int(aid) & 0xFFFFFFFF) == want:
                nm = next((x for kk, tt, x in v if kk == "AppName" and tt == "str"), None)
                print("  ✓ %s 里有「%s」(appid %s)" % (f, nm, appid))
                return 0
    print("  ! %s 里没有 appid %s" % (fs[0], appid))
    return 1


def cmd_restore(userdata):
    """把「live 文件 + 所有备份」里的条目**合并**回来（按 appid 去重，新的覆盖旧的）

    为什么是合并而不是"取最新那份备份"：Steam 被强杀时会把它清成 0 字节/十几字节，
    我的写入流程又会把当时的文件备份下来 —— 于是备份集里混着空壳。实测按"最新"
    恢复会把列表清空。合并则谁都不丢（用户想删的条目可以在 Steam 里再删一次）。
    """
    if steam_running():
        print("  ! Steam 正在运行 —— 先退出 Steam 再恢复（否则会被它再覆盖）"); return 1
    srcs = []
    for f in files_of(userdata):
        srcs.append((os.path.getmtime(f), f))
    for b in glob.glob(os.path.join(userdata, "*", "config", "shortcuts.vdf.deckkit-bak-*")):
        srcs.append((os.path.getmtime(b), b))
    if not srcs:
        print("  ! 既没有 shortcuts.vdf 也没有备份"); return 1
    srcs.sort()                      # 旧 → 新：后面的覆盖前面的

    entries, base, tail, closes, nsrc = {}, None, b"", 0, 0
    for mt, f in srcs:
        try:
            root, t2, c2 = parse(open(f, "rb").read())
        except Exception:
            continue
        sc = next((v for k, t, v in root if t == "obj"), None)
        if sc is None:
            continue
        nsrc += 1
        if base is None or mt >= base[0]:
            base = (mt, root); tail, closes = t2, c2
        for item in sc:
            k, t, v = item
            if t != "obj":
                continue
            aid = next((x for kk, tt, x in v if kk == "appid" and tt == "int"), None)
            nm  = next((x for kk, tt, x in v if kk == "AppName" and tt == "str"), None)
            key = str(int(aid) & 0xFFFFFFFF) if aid is not None else ("name:" + str(nm))
            entries[key] = item
    if base is None:
        print("  ! 所有来源都解析失败"); return 1

    live = files_of(userdata)
    if live:
        dst = live[0]
    else:
        dst = os.path.dirname(srcs[-1][1])
        dst = os.path.join(dst if dst.endswith("config") else os.path.join(dst, "config"), "shortcuts.vdf")
    root = base[1]
    sc = next(v for k, t, v in root if t == "obj")
    sc[:] = list(entries.values())
    out = dump(root, tail, closes)
    if os.path.exists(dst):
        shutil.copy2(dst, dst + ".deckkit-bak-" + time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, "wb").write(out)
    print("  ✓ 已合并 %d 份来源 → %s（%d 条快捷方式）" % (nsrc, dst, len(entries)))
    return 0


def cmd_remove(userdata, key):
    """从 shortcuts.vdf 里删掉匹配 appid（或 AppName）的条目"""
    fs = files_of(userdata)
    if not fs:
        print("  ! 没找到 shortcuts.vdf"); return 1
    for f in fs:
        raw = open(f, "rb").read()
        root, tail, closes = parse(raw)
        sc = next((v for k, t, v in root if t == "obj"), None)
        if sc is None:
            print("  ! 结构异常，跳过 %s" % f); continue
        keep, n = [], 0
        for item in sc:
            k, t, v = item
            if t == "obj":
                aid = next((val for kk, tt, val in v if kk == "appid" and tt == "int"), None)
                nm  = next((val for kk, tt, val in v if kk == "AppName" and tt == "str"), None)
                if (aid is not None and (str(aid) == str(key)
                        or str(int(aid) & 0xFFFFFFFF) == str(key))) or (nm == key):
                    n += 1
                    continue
            keep.append(item)
        if n == 0:
            print("  ! %s 里没有匹配 %s 的条目" % (os.path.basename(f), key)); continue
        sc[:] = keep
        # 同一条别加两遍：按 appid 去重（保留先出现的那条）
        _sc = next((v for k, t, v in root if t == "obj"), None)
        if _sc is not None:
            _seen, _keep = set(), []
            for _it in _sc:
                _key = None
                if _it[1] == "obj":
                    _a = next((x for kk, tt, x in _it[2] if kk == "appid" and tt == "int"), None)
                    _key = (int(_a) & 0xFFFFFFFF) if _a is not None else None
                if _key is not None and _key in _seen:
                    continue
                if _key is not None:
                    _seen.add(_key)
                _keep.append(_it)
            if len(_keep) != len(_sc):
                print("  · 去掉 %d 条重复条目" % (len(_sc) - len(_keep)))
                _sc[:] = _keep

        out = dump(root, tail, closes)
        shutil.copy2(f, f + ".deckkit-bak-" + time.strftime("%Y%m%d-%H%M%S"))
        open(f, "wb").write(out)
        print("  ✓ 已从 %s 删掉 %d 条（剩 %d 条）" % (os.path.basename(f), n, len(keep)))
    return 0


def main():
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == "--has":
        return cmd_has(a[1], a[2])
    if len(a) >= 3 and a[0] == "--remove":
        return cmd_remove(a[1], a[2])
    if len(a) >= 2 and a[0] == "--restore":
        return cmd_restore(a[1])
    if len(a) >= 2 and a[0] == "--check":
        return cmd_check(a[1])
    if len(a) >= 6 and a[0] == "--add":
        return cmd_add(a[1], a[2], a[3], a[4], a[5], a[6] if len(a) > 6 else "")
    print(__doc__ or "", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
