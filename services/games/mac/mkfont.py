#!/usr/bin/env python3
"""deckkit games —— 生成「多 Windows 字体名」的中文 TTC（Mac 侧跑，需要 fontTools）。

用途：喂给 Wine / Proton（见 deck/winfonts.sh）。把一份覆盖 GB18030 的 TrueType
字体（Deck 上 Proton 自带的 share/fonts/msyh.ttf，内部其实是 Source Han Sans SC，
glyf 轮廓、44,812 个码位）复制成多个「Windows 上真实存在」的 family 名，做成一个
TTC。Wine 扫描 fonts 目录时按文件里的 family 名注册，于是这些名字就直接命中了。

为什么是这些名字（都是实测出来的）：
  · SRPG Studio 系汉化游戏把 UI 字体写死在 data.dts 的项目段里，值就是 "MS Gothic"；
    而 Proton 自带的 msgothic.ttc 其实是 Ume-Gothic（只有 JIS 字形），
    「头/开/结/戏/环/继/续」这类简体字一个都没有 → 游戏里直接空白。
  · 終曲那款项目段里没写字体 → 引擎退回写死在 game.exe 里的 "Meiryo UI"；
    prefix 里根本没有这个 family → 无字体可用 → 豆腐块。
  · Wine 的 SystemLink 兜底链（Tahoma / System / MS Shell Dlg → MSGOTHIC.TTC,MS UI
    Gothic）同样指向 Ume-Gothic；链里那条 `MSYH.TTC,Microsoft YaHei UI` 因为
    Proton 只放了 msyh.ttf（文件名对不上）而断掉 → 中文兜底也接不上。

用法：
    python3 mkfont.py <源.ttf> <输出.ttc>
"""
import os
import sys

from fontTools.ttLib import TTFont, TTCollection
from fontTools.ttLib.tables._n_a_m_e import table__n_a_m_e

# (英文 family, 英文 subfamily, PostScript 名, 额外本地化名 [(langID, 名字)])
FACES = [
    ("MS Gothic", "Regular", "DeckkitMSGothic",
     [(0x411, "\uff2d\uff33 \u30b4\u30b7\u30c3\u30af")]),
    ("MS PGothic", "Regular", "DeckkitMSPGothic",
     [(0x411, "\uff2d\uff33 \uff30\u30b4\u30b7\u30c3\u30af")]),
    ("MS UI Gothic", "Regular", "DeckkitMSUIGothic", []),
    ("Meiryo", "Regular", "DeckkitMeiryo",
     [(0x411, "\u30e1\u30a4\u30ea\u30aa")]),
    ("Meiryo UI", "Regular", "DeckkitMeiryoUI",
     [(0x411, "\u30e1\u30a4\u30ea\u30aaUI")]),
    ("Microsoft YaHei", "Regular", "DeckkitMSYaHei",
     [(0x804, "\u5fae\u8f6f\u96c5\u9ed1")]),
    ("Microsoft YaHei UI", "Regular", "DeckkitMSYaHeiUI",
     [(0x804, "\u5fae\u8f6f\u96c5\u9ed1 UI")]),
]

# 自检用：这些字必须都有字形（简中常见字 + 日文假名）
PROBE = "从新开始境束游戏结环设置头存档继续结束はがです"


def _make_name(family, subfamily, ps, extras):
    nm = table__n_a_m_e()
    nm.names = []
    full = f"{family} {subfamily}"
    for nid, val in ((1, family), (2, subfamily),
                     (3, f"{full};deckkit;{ps}"), (4, full), (6, ps)):
        nm.setName(val, nid, 3, 1, 0x409)
    for lang, val in extras:
        nm.setName(val, 1, 3, 1, lang)
        nm.setName(subfamily, 2, 3, 1, lang)
        nm.setName(full, 4, 3, 1, lang)
    return nm


def build(src, dst):
    base = TTFont(src, recalcBBoxes=False, recalcTimestamp=False)
    cmap = base.getBestCmap()
    missing = [c for c in PROBE if ord(c) not in cmap]
    if missing:
        raise SystemExit(f"源字体缺字形：{''.join(missing)} —— 换一份覆盖简中的字体")

    glyph_order = base.getGlyphOrder()
    # name 必须每个 face 一份；其它大表（glyf/loca/cmap/GPOS…）共享，TTC 里只存一遍
    shared = {t: base[t] for t in base.keys() if t not in ("GlyphOrder", "name")}

    faces = []
    for family, subfamily, ps, extras in FACES:
        f = TTFont()
        f.setGlyphOrder(glyph_order)
        for tag, table in shared.items():
            f[tag] = table
        f["name"] = _make_name(family, subfamily, ps, extras)
        faces.append(f)

    coll = TTCollection()
    coll.fonts = faces
    try:
        coll.save(dst, shareTables=True)
    except TypeError:            # 老版本 fontTools 没这个参数
        coll.save(dst)
    print(f"{dst}  {os.path.getsize(dst) / 1048576:.1f} MB  faces={len(faces)}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    build(sys.argv[1], sys.argv[2])
