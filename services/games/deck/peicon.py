#!/usr/bin/env python3
# ============================================================
#  deckkit / games —— 从 Windows exe/dll 里抠图标（纯 Python，无依赖）
#
#    peicon.py <exe> <输出目录>        把每个尺寸的图标各存一张 PNG（大的在前）
#    peicon.py <exe> --best <文件.png> 只输出最大的那张
#    peicon.py <exe> --list            只列一下有哪些尺寸
#
#  为什么自己解析：Deck 上没有 icoutils（也不方便往 SteamOS 里装），
#  而我们要的就是「游戏主程序自带的图标」——它是 exe 的 PE 资源
#  （RT_GROUP_ICON 描述 + RT_ICON 数据），格式不难，纯 Python 够用。
# ============================================================
import os
import struct
import sys
import zlib


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def i32(b, o):
    return struct.unpack_from("<i", b, o)[0]


class PE:
    def __init__(self, data):
        self.d = data
        if data[:2] != b"MZ":
            raise ValueError("不是 PE 文件（没有 MZ）")
        self.pe = u32(data, 0x3C)
        if data[self.pe:self.pe + 4] != b"PE\0\0":
            raise ValueError("不是 PE 文件（没有 PE\\0\\0）")
        coff = self.pe + 4
        self.nsec = u16(data, coff + 2)
        opt_size = u16(data, coff + 16)
        self.opt = coff + 20
        magic = u16(data, self.opt)
        if magic == 0x20B:
            self.dd = self.opt + 112
        elif magic == 0x10B:
            self.dd = self.opt + 96
        else:
            raise ValueError("不认识的 optional header magic：0x%x" % magic)
        self.sections = []
        sec = self.opt + opt_size
        for i in range(self.nsec):
            o = sec + i * 40
            self.sections.append((
                u32(data, o + 12),                 # VirtualAddress
                u32(data, o + 8),                  # VirtualSize
                u32(data, o + 20),                 # PointerToRawData
                u32(data, o + 16),                 # SizeOfRawData
            ))

    def off(self, rva):
        for va, vsize, praw, rawsize in self.sections:
            if va <= rva < va + max(vsize, rawsize):
                return rva - va + praw
        raise ValueError("RVA 0x%x 不在任何段里" % rva)

    def resources(self):
        """返回 {类型: {名字/ID: [数据, ...]}}（这里只关心 3=RT_ICON、14=RT_GROUP_ICON）"""
        rva = u32(self.d, self.dd + 2 * 8)
        if rva == 0:
            return {}
        base = self.off(rva)
        out = {}

        # 三层：类型（RT_ICON=3 / RT_GROUP_ICON=14）→ 资源 ID → 语言 → 数据。
        # 键一定是**类型**，ID 留在里层 —— 第一版把 ID 当成了外层键，
        # 于是 res[14] 变成列表、其它 exe 干脆查不到图标（实测全被误判成"没图标"）。
        def walk(off, level, typ=None, rid=None):
            n_named = u16(self.d, off + 12)
            n_id = u16(self.d, off + 14)
            for i in range(n_named + n_id):
                e = off + 16 + i * 8
                name = u32(self.d, e)
                sub = u32(self.d, e + 4)
                if level == 0:
                    walk(base + (sub & 0x7FFFFFFF), 1, name, None)
                elif level == 1:
                    walk(base + (sub & 0x7FFFFFFF), 2, typ, name)
                else:
                    de = base + sub
                    data_rva = u32(self.d, de)
                    size = u32(self.d, de + 4)
                    o = self.off(data_rva)
                    out.setdefault(typ, {}).setdefault(rid, []).append(self.d[o:o + size])

        walk(base, 0)
        return out


def png_bytes(w, h, rgba):
    raw = b"".join(b"\x00" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def dib_to_rgba(buf):
    """RT_ICON 里的位图：BITMAPINFOHEADER + 调色板 + XOR 位 + AND 掩码"""
    hdr = u32(buf, 0)
    if hdr < 40:
        raise ValueError("不支持的 DIB 头（%d 字节）" % hdr)
    w = i32(buf, 4)
    h2 = i32(buf, 8)
    bpp = u16(buf, 14)
    compression = u32(buf, 16)
    if compression not in (0, 3):
        raise ValueError("不支持的压缩方式 %d" % compression)
    topdown = h2 < 0
    h = abs(h2) // 2 if not topdown else abs(h2) // 2
    # 图标 DIB 的高度是「两倍」：XOR 图 + AND 掩码
    h = abs(h2) // 2

    pal = []
    off = hdr
    if bpp <= 8:
        n = u32(buf, 32) or (1 << bpp)
        for i in range(n):
            b, g, r, _a = buf[off + i * 4: off + i * 4 + 4]
            pal.append((r, g, b))
        off += n * 4

    row_xor = ((w * bpp + 31) // 32) * 4
    rgba = bytearray(w * h * 4)

    def get_px(x, y):
        """返回 (r,g,b,a)，y 已经换成「从下往上」的原始行号"""
        base = off + y * row_xor
        if bpp == 32:
            b, g, r, a = buf[base + x * 4: base + x * 4 + 4]
            return r, g, b, a
        if bpp == 24:
            b, g, r = buf[base + x * 3: base + x * 3 + 3]
            return r, g, b, 255
        if bpp == 8:
            r, g, b = pal[buf[base + x]]
            return r, g, b, 255
        if bpp == 4:
            v = buf[base + x // 2]
            idx = (v >> 4) if x % 2 == 0 else (v & 0xF)
            r, g, b = pal[idx]
            return r, g, b, 255
        if bpp == 1:
            v = buf[base + x // 8]
            idx = (v >> (7 - x % 8)) & 1
            r, g, b = pal[idx]
            return r, g, b, 255
        raise ValueError("不支持的位深 %d" % bpp)

    for y in range(h):
        src_y = y if topdown else (h - 1 - y)      # DIB 默认自下而上
        for x in range(w):
            r, g, b, a = get_px(x, src_y)
            o = (y * w + x) * 4
            rgba[o] = r
            rgba[o + 1] = g
            rgba[o + 2] = b
            rgba[o + 3] = a

    # 老图标（24/8 位深）没有 alpha 通道，全 0 的话当不透明处理
    if bpp != 32 or all(rgba[i] == 0 for i in range(3, len(rgba), 4)):
        for o in range(3, len(rgba), 4):
            rgba[o] = 255
    return w, h, bytes(rgba)


def icons_of(path):
    """返回 [(w, h, png_bytes), ...]，大的在前"""
    data = open(path, "rb").read()
    pe = PE(data)
    res = pe.resources()
    groups = res.get(14, {})
    entries = []
    for _gid, blobs in groups.items():
        for g in blobs:
            if len(g) < 6:
                continue
            count = u16(g, 4)
            for i in range(count):
                e = 6 + i * 14
                if e + 14 > len(g):
                    break
                bw, bh, _cc, _rs = g[e], g[e + 1], g[e + 2], g[e + 3]
                bitcount = u16(g, e + 6)
                nid = u16(g, e + 12)
                entries.append((bw or 256, bh or 256, bitcount, nid))
    out = []
    for bw, bh, bitcount, nid in entries:
        blobs = res.get(3, {}).get(nid)
        if not blobs:
            continue
        blob = blobs[0]
        try:
            if blob[:8] == b"\x89PNG\r\n\x1a\n":        # Vista+ 的 256×256 直接存 PNG
                out.append((bw, bh, blob))
            else:
                w, h, rgba = dib_to_rgba(blob)
                out.append((w, h, png_bytes(w, h, rgba)))
        except Exception:
            continue
    # 去重（同尺寸只留位深最高/最大的那份）并大的在前
    seen = {}
    for w, h, png in out:
        if (w, h) not in seen or len(png) > len(seen[(w, h)]):
            seen[(w, h)] = png
    return sorted(((w, h, p) for (w, h), p in seen.items()),
                  key=lambda t: -(t[0] * t[1]))


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__ or "", file=sys.stderr)
        return 2
    exe = a[0]
    if not os.path.isfile(exe):
        print("找不到文件：%s" % exe, file=sys.stderr)
        return 1
    try:
        ics = icons_of(exe)
    except Exception as e:
        print("解析失败：%s" % e, file=sys.stderr)
        return 1
    if not ics:
        print("这个 exe 里没有图标资源", file=sys.stderr)
        return 1

    if len(a) >= 3 and a[1] == "--best":
        w, h, png = ics[0]
        open(a[2], "wb").write(png)
        print("%s\t%dx%d" % (a[2], w, h))
        return 0
    if len(a) >= 2 and a[1] == "--list":
        for w, h, _p in ics:
            print("%dx%d" % (w, h))
        return 0

    outdir = a[1] if len(a) >= 2 else "."
    os.makedirs(outdir, exist_ok=True)
    for w, h, png in ics:
        p = os.path.join(outdir, "icon-%dx%d.png" % (w, h))
        open(p, "wb").write(png)
        print("%s\t%dx%d" % (p, w, h))
    return 0


if __name__ == "__main__":
    sys.exit(main())
