#!/usr/bin/env python3
"""给非 Steam 快捷方式安装 Steam Input 手柄布局（Deck 侧运行）。

Steam 把每个 app 的手柄布局存在：
    ~/.local/share/Steam/steamapps/common/Steam Controller Configs/<steamid>/config/<key>/controller_neptune.vdf
并在同目录的 configset_controller_neptune.vdf 里用
    "<key>" { "autosave" "1" }
登记"这个 app 用它自己的布局"。

**key 的规则**（实测对出来的：`MyGame2 V2.0版+…` → `MyGame2 v20版+…`、
`UkiyoGensoEnnichi` → `ukiyogensoennichi`）：名字转小写 + 去掉 `.`。
注意：非 Steam 快捷方式用的是**名字**当 key（不是 appid）—— 因为改名字以后 appid 会变。

本脚本做三件事：list（看现状）/ install（写布局 + 登记）/ remove（撤掉）。
install 时 header 字段照 Steam 自己写的那份（creator/progenitor/url/export_type/
controller_caps…），映射本体（localization/group/preset…）直接取模板。
"""
import argparse
import os
import re
import shutil
import sys

TEMPLATE_DIRS = [
    os.path.expanduser("~/.steam/steam/controller_base/templates"),
    os.path.expanduser("~/.local/share/Steam/controller_base/templates"),
]
ALIASES = {
    "mouse": "controller_neptune_mouse.vdf",
    "仅鼠标": "controller_neptune_mouse.vdf",
    "gamepad+mouse": "controller_neptune_gamepad+mouse.vdf",
    "手柄+鼠标": "controller_neptune_gamepad+mouse.vdf",
    "wasd": "controller_neptune_wasd.vdf",
    "webbrowser": "controller_neptune_webbrowser.vdf",
    "fps": "controller_neptune_gamepad_fps.vdf",
    "joystick": "controller_neptune_gamepad_joystick.vdf",
    "touchscreen": "controller_neptune_touchscreen.vdf",
    "gyro": "controller_neptune_gamepad_mouse_gyro.vdf",
}


def key_of(name):
    """Steam 的 key 规则：小写 + 去点（实测验证过两个真实目录）。"""
    return name.lower().replace(".", "")


def find_template(alias):
    fname = ALIASES.get(alias, alias)
    if not fname.endswith(".vdf"):
        fname += ".vdf"
    for d in TEMPLATE_DIRS:
        p = os.path.join(d, fname)
        if os.path.isfile(p):
            return p
    return None


def find_config_dir(root):
    """root = .../Steam Controller Configs/<steamid>/config（调用方一般直接给）"""
    return root


def split_mappings(text):
    """把 controller_mappings 拆成 (header 行, 从 localization 开始的本体)"""
    lines = text.splitlines(True)
    body_at = None
    for i, ln in enumerate(lines):
        if re.match(r'^\t"localization"\s*$', ln):
            body_at = i
            break
    if body_at is None:
        return lines, []
    return lines[:body_at], lines[body_at:]


def creator_from_existing(cfgdir):
    """抄一份已有配置里的 creator（steamid64）；没有就按 accountid 算。"""
    try:
        for name in sorted(os.listdir(cfgdir)):
            p = os.path.join(cfgdir, name, "controller_neptune.vdf")
            if not os.path.isfile(p):
                continue
            for ln in open(p, encoding="utf-8", errors="replace"):
                m = re.match(r'^\t"creator"\s+"(\d+)"\s*$', ln)
                if m:
                    return m.group(1)
    except OSError:
        pass
    acct = os.path.basename(os.path.dirname(os.path.abspath(cfgdir)))    # .../<accountid>/config
    if acct.isdigit():
        return str(76561197960265728 + int(acct))                       # 个人账号的 steamid64 基址
    return ""


def caps_from_existing(cfgdir):
    """从任意已存在的 app 配置里抄 controller_caps（Deck 手柄的能力位）。"""
    try:
        for name in sorted(os.listdir(cfgdir)):
            p = os.path.join(cfgdir, name, "controller_neptune.vdf")
            if not os.path.isfile(p):
                continue
            for ln in open(p, encoding="utf-8", errors="replace"):
                m = re.match(r'^\t"controller_caps"\s+"(\d+)"\s*$', ln)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return "23117823"          # 实测你这台 Deck 上的值


def build_header(appid, creator, url_path, caps):
    """照着 Steam 自己写的那份 header（字段顺序/缩进都一致，别自己发挥）。"""
    lines = [
        '"controller_mappings"',
        '{',
        '\t"version"\t\t"3"',
        '\t"revision"\t\t"1"',
        '\t"title"\t\t"#Title"',
        '\t"description"\t\t"#SettingsController_AutosaveDescription"',
        '\t"creator"\t\t"%s"' % creator,
        '\t"progenitor"\t\t"default://%s"' % appid,
        '\t"url"\t\t"autosave://%s"' % url_path,
        '\t"export_type"\t\t"unknown"',
        '\t"controller_type"\t\t"controller_neptune"',
        '\t"controller_caps"\t\t"%s"' % caps,
        '\t"major_revision"\t\t"0"',
        '\t"minor_revision"\t\t"0"',
        '\t"Timestamp"\t\t"0"',
    ]
    return "\n".join(lines) + "\n"


def configset_keys(path):
    if not os.path.isfile(path):
        return []
    txt = open(path, encoding="utf-8", errors="replace").read()
    return re.findall(r'^\t"([^"]+)"\s*$', txt, re.M)


def register_key(cfgset, key, dry):
    txt = open(cfgset, encoding="utf-8", errors="replace").read()
    if key in configset_keys(cfgset):
        return "already", txt
    block = '\t"%s"\n\t{\n\t\t"autosave"\t\t"1"\n\t}\n' % key
    m = re.search(r'^"controller_config"\s*\n\{\n', txt, re.M)
    if not m:
        m = re.search(r'^\{\n', txt, re.M)
        if not m:
            return "no-anchor", txt
    out = txt[:m.end()] + block + txt[m.end():]
    return "inserted", out


def do_list(cfgdir, games):
    cfgset = os.path.join(cfgdir, "configset_controller_neptune.vdf")
    keys = set(configset_keys(cfgset))
    print("配置目录：%s" % cfgdir)
    print("已登记（configset）：%d 个 key" % len(keys))
    print()
    print("%-44s %-40s %-8s %s" % ("游戏", "Steam key", "目录", "当前布局"))
    for name, appid in games:
        k = key_of(name)
        d = os.path.join(cfgdir, k)
        f = os.path.join(d, "controller_neptune.vdf")
        title = "-"
        if os.path.isfile(f):
            txt = open(f, encoding="utf-8", errors="replace").read()
            m = re.search(r'"english"\s*\n\s*\{\s*\n\s*"title"\s*"([^"]+)"', txt)
            if m:
                title = m.group(1)
        print("%-44s %-40s %-8s %s" % (
            name[:42], k[:38], "有" if os.path.isdir(d) else "无",
            title if title != "-" else ("（未登记）" if k not in keys else "（登记了但没文件）")))


def do_install(cfgdir, name, appid, alias, creator, key, dry, outdir):
    tpl = find_template(alias)
    if not tpl:
        print("找不到模板：%s（可选：%s）" % (alias, "、".join(sorted(ALIASES))), file=sys.stderr)
        return 1
    k = key or key_of(name)
    target_dir = os.path.join(cfgdir, k)
    target = os.path.join(target_dir, "controller_neptune.vdf")
    cfgset = os.path.join(cfgdir, "configset_controller_neptune.vdf")
    caps = caps_from_existing(cfgdir)
    if not creator:
        creator = creator_from_existing(cfgdir)
    tpl_text = open(tpl, encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
    body = split_mappings(tpl_text)[1]
    content = build_header(appid, creator, target, caps) + "".join(body)
    status, newset = register_key(cfgset, k, dry)

    print("模板    ：%s（%s）" % (os.path.basename(tpl), alias))
    print("Steam key：%s" % k)
    print("布局文件：%s" % target)
    print("登记    ：%s" % {"inserted": "会插入到 configset", "already": "已经登记过",
                            "no-anchor": "configset 结构不认识（跳过登记）"}[status])
    if dry:
        od = outdir or os.path.join(os.path.expanduser("~"), "deckkit-pad-dryrun")
        os.makedirs(os.path.join(od, k), exist_ok=True)
        open(os.path.join(od, k, "controller_neptune.vdf"), "w", encoding="utf-8", newline="\n").write(content)
        if status == "inserted":
            open(os.path.join(od, "configset_controller_neptune.vdf"), "w", encoding="utf-8").write(newset)
        print("dry-run ：写到 %s（没碰 Steam 的目录）" % od)
        return 0

    os.makedirs(target_dir, exist_ok=True)
    if os.path.isfile(target) and not os.path.isfile(target + ".deckkit-bak"):
        shutil.copy2(target, target + ".deckkit-bak")
        print("备份    ：%s.deckkit-bak" % target)
    open(target, "w", encoding="utf-8", newline="\n").write(content)
    if status == "inserted":
        if not os.path.isfile(cfgset + ".deckkit-bak"):
            shutil.copy2(cfgset, cfgset + ".deckkit-bak")
        open(cfgset, "w", encoding="utf-8").write(newset)
    print("已写入 ✓")
    return 0


def do_remove(cfgdir, name, key):
    k = key or key_of(name)
    d = os.path.join(cfgdir, k)
    cfgset = os.path.join(cfgdir, "configset_controller_neptune.vdf")
    if os.path.isfile(os.path.join(d, "controller_neptune.vdf.deckkit-bak")):
        shutil.move(os.path.join(d, "controller_neptune.vdf.deckkit-bak"),
                    os.path.join(d, "controller_neptune.vdf"))
        print("已还原备份：%s" % os.path.join(d, "controller_neptune.vdf"))
    if os.path.isdir(d):
        shutil.rmtree(d)
        print("已删除布局目录：%s" % d)
    else:
        print("没有布局目录：%s" % d)
    if os.path.isfile(cfgset):
        txt = open(cfgset, encoding="utf-8", errors="replace").read()
        pat = re.compile(r'^\t"%s"\n\t\{\n(?:[^\n]*\n)*?\t\}\n' % re.escape(k), re.M)
        if pat.search(txt):
            open(cfgset, "w", encoding="utf-8").write(pat.sub("", txt, count=1))
            print("已从 configset 去掉登记：%s" % k)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["list", "install", "remove"])
    ap.add_argument("--cfgdir", required=True)
    ap.add_argument("--game", action="append", default=[], help="名字<TAB>appid，可重复")
    ap.add_argument("--games-file", help="每行 appid<TAB>名字")
    ap.add_argument("--name")
    ap.add_argument("--appid")
    ap.add_argument("--template", default="mouse")
    ap.add_argument("--key")
    ap.add_argument("--creator", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--outdir")
    a = ap.parse_args()
    games = []
    for g in a.game:
        parts = g.split("\t")
        games.append((parts[0], parts[1] if len(parts) > 1 else ""))
    if a.games_file and os.path.isfile(a.games_file):
        for ln in open(a.games_file, encoding="utf-8", errors="replace"):
            ln = ln.rstrip("\n")
            if not ln:
                continue
            ap_, _, nm_ = ln.partition("\t")
            games.append((nm_, ap_))
    if a.appid:                      # 按 appid 把名字捞出来（避开中文名转义）
        hit = [n for n, i in games if i == a.appid]
        if hit:
            a.name = hit[0]
        games = [(n, i) for n, i in games if i != a.appid] or games
    if a.action == "list":
        if not games:
            print("需要 --game 或 --games-file", file=sys.stderr)
            return 2
        do_list(a.cfgdir, games)
        return 0
    if not a.name:
        print("install/remove 需要 --name（或 --appid 配合 --games-file）", file=sys.stderr)
        return 2
    if not a.appid:
        a.appid = "0"
    if a.action == "install":
        return do_install(a.cfgdir, a.name, a.appid, a.template, a.creator, a.key, a.dry_run, a.outdir)
    return do_remove(a.cfgdir, a.name, a.key)


if __name__ == "__main__":
    sys.exit(main())
