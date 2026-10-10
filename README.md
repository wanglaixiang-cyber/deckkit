# deckkit

在 **Steam Deck** 上装非 Steam 游戏、给游戏打补丁的省事工具：
Windows 游戏一条命令装好并登记进 Steam 库，补丁解包后挂载进游戏目录。
最初只是想让 Deck 跑一个本地网络节点 —— 顺手长成了一个「一机多服务」的小框架。

> **vibe coding 项目**：代码主要由 AI（**DeepSeek V4.1**）写，人在真机上验收 ——
> 见下面的《它是怎么来的》。
> 个人自用工具，按需取用：`services/*/mac/config.env` 里的路径、主机名、网段
> 都要改成你自己的；只在 macOS + Steam Deck（SteamOS 3.x）上实测过。
> 许可：[MIT](LICENSE)。

框架本身只做三件事：**统一入口**、**两机协作约定**、**菜单栏总览**。
具体功能都是挂在 `services/` 下面的独立服务。

```
deckkit/
├── bin/deck                 统一 CLI（服务分发 + 内建运维命令 + 各服务命令清单）
├── menubar/                 菜单栏 App（Deck 状态 + 各服务一行状态 + 点开终端）
├── services/                各服务，每个自带 mac/ 与 deck/ 两侧
│   ├── files/               Deck 家目录共享给 Mac（访达侧边栏里的「deck」）
│   ├── patches/             Steam 游戏补丁：解包 → 挂载进游戏目录
│   └── games/               Windows 游戏装到 Deck（Proton prefix + Steam 条目）
├── docs/
│   ├── 约定.md              两机协作约定 + 改动纪律（加新服务前先读）
│   └── 历史-萤石NAS时期.md   更早那套方案的存档
├── _archive/                已退役的东西（原 backup 服务的部署包）
└── README.md                本文件
```

---

## 快速开始

```bash
# 概览：有哪些服务、Deck 在不在线、各自什么状态
deck                       # 已装到 PATH（deck self-install 装的）；也可以用 ./bin/deck

# 建个软链，之后直接用 deck
ln -sf "$(pwd)/bin/deck" ~/.local/bin/deck   # 在仓库根目录执行（或直接跑 deck self-install）

deck                       # 概览
deck list                  # 服务清单
deck status                # 所有服务的状态
deck files mount           # 把 Deck 家目录挂到访达
deck menu --run            # 编译并启动菜单栏 App
deck ssh                   # SSH 到 Deck
deck doctor                # 环境体检
```

---

## 内建命令

| 命令 | 作用 |
|---|---|
| `deck` | 概览：根目录、Deck 连通性、各服务一行状态 |
| `deck list` | 列出所有服务及一句话说明 |
| `deck status [服务]` | 查看状态（不指定则全部） |
| `deck <服务> <子命令>` | 转发给 `services/<服务>/service` |
| `deck menu [--run]` | 编译（并启动）菜单栏 App |
| `deck vitals [--json]` | 读 Deck 电量 / 充电状态 / 温度 / 运行时长 / 负载 |
| `deck ensure [服务]` | 让服务自愈（幂等）：`files` 没挂上就挂上 |
| `deck toggle <服务>` | 切换服务主状态：例如 `files` 是挂载 / 卸载 |
| `deck ssh [命令]` | SSH 到 Deck（走 `~/.ssh/config` 的 `deck` 别名） |
| `deck root <命令>` | 以 root 在 Deck 上执行（需要免密 sudo） |
| `deck push <本地> <远端>` | 传文件到 Deck |
| `deck help` | 用法 + **每个服务最常用的命令**（按服务分段） |
| `deck cmds` | 只列各服务的常用命令 |
| `deck self-install` | 把 `deck` 放进 PATH（之后任意目录直接敲 `deck`） |
| `deck doctor` | 检查 Deck 可达性 / 免密 sudo / swiftc / 菜单栏产物 / 脚本里的全角字符坑 |

---

## 菜单栏 App

常驻菜单栏，一眼看清 Deck 和所有服务的状态。

```bash
deck menu --install     # 编译 + 装到 /Applications/DeckKit.app 并启动（推荐）
deck menu               # 装了之后：编译 → 重新安装 → 重启那份（改动直接生效）
deck menu --dev         # 只想编仓库里那份（menubar/DeckKit.app），别碰 /Applications
```

- **装到 `/Applications` 之后那份是正主**：它在 `Info.plist` 的 `DeckkitRoot` 里
  记着仓库路径，靠它找 `services/` 与 `bin/deck` —— 所以仓库别删、别乱挪，
  挪了重新 `deck menu --install` 一次。开机自启就加它：
  系统设置 → 通用 → 登录项 → 添加 `DeckKit.app`。
- **图标由代码画**（`menubar/makeicon.swift`，官方 logo 的机身标记 + 圆角深色底），
  仓库里不放二进制素材；`menubar/AppIcon.icns` 是构建产物，不进版本库。

- **图标**：Steam Deck 官方 logo 的机身标记（template image，自动适配浅色/深色菜单栏）；
  Deck 离线时整个图标压暗。
- **第一栏**：Deck 在线状态、主机名与刷新时间，再加一行遥测 ——
  电量、充电状态、APU 温度、已开机时长。在用电池时这一行标黄
  （对一台常驻服务器来说靠电池跑是要留意的）；完整读数（含电池温度、负载）
  在鼠标悬停图标时的 tooltip 里。
- **服务栏**：每个服务一行摘要（取各自 `service status` 的第一行）。
  **点一下**会在终端里执行动作、紧接着显示完整状态（地址、端口、数据量…）——
  不用记「这个服务是干什么的、在哪个地址」；启动要等几十秒的那种
  动作，进度也是实时可见的，而不是静默等。点击提示由服务通过 `caps` 自己给出。
- **自愈**：每轮刷新（30 秒）都跑一次 `deck ensure` —— 实测挂载会在 Deck **一直在线**
  的情况下自己掉，只在启动时补是不够的。手动卸载会被记住（服务侧的「期望状态」标记），
  不会被自愈覆盖；刚点过服务的 90 秒内也会跳过自愈，免得和终端里的操作抢。
- **生命周期和图标绑定**：没有常驻 launchd 代理，退出 App 就真的不再自愈/补挂。
  只要 App 在跑图标就一直在；Deck 离线时图标压暗，但不会消失。
- **它还负责代跑前端**：这台 Mac 上，终端启动的 `node` 连不到局域网 —— macOS
  「本地网络」权限是按**启动它的 App** 判定的，而终端拿不到（系统设置里连条目
  都不生成）。所以 `deck <服务> web start` 会先探一次当前上下文，探不通就写请求
  文件 + `open -a` 请菜单栏 App 以自己的身份启动前端（父进程决定权限）。
  结论：**前端要经过框架入口启动（`deck <服务> web start`），不要手动 `npm run dev`**。
- **休眠 / 唤醒**：重复 Timer 在系统睡眠期间不走，醒来只补一次，所以只靠定时器
  会出现「醒来后状态还停在睡前」。App 订阅了 `willSleep` / `didWake`：
  睡前把状态标成「检测中…」（不再亮着一个无法保证的绿灯），醒来立刻重刷。
  探测超时（不是「离线」，是「问不出来」）同样显示「检测中…」，不画假红点。

遥测和在线探测走**同一趟 SSH**（`deck vitals --json`），不会让每次刷新等两轮。

```bash
deck menu          # 编译
deck menu --run    # 编译并启动
deck vitals        # 命令行里看同一份读数
```

菜单栏点不开时（或想在脚本里检查）可以用无界面自检：

```bash
deckkit/menubar/DeckKit.app/Contents/MacOS/DeckKit --dump   # 打印菜单内容后退出
```

图标会随 Deck 在线状态变化，并且只在后台线程探测（约定 §5：绝不阻塞主线程）。
开机自启：系统设置 → 通用 → 登录项 → 添加 `DeckKit.app`。

---

## 加一个新服务

只做三步，不用改框架代码：

```bash
mkdir -p services/<名字>/{mac,deck}

cat > services/<名字>/service <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-status}" in
  status) echo "✓ 一行人类可读的摘要" ;;   # ← 必须实现，且是第一行
  run)    echo "干活…" ;;
  *)      echo "不认识子命令：$1" >&2; exit 2 ;;
esac
EOF
chmod 755 services/<名字>/service

echo "# 我这个服务干什么" > services/<名字>/SERVICE.md
```

然后 `deck list` / `deck status` / `deck <名字> run` 就都能用了，
**菜单栏里的那一行摘要也会自动出现**（它读的就是 `status` 的第一行）。

细节见 [`docs/约定.md`](docs/约定.md)。

---

## 现有服务

### `patches` —— Steam 游戏补丁

```bash
deck patches ls                      # 补丁库 + 挂载状态
deck patches games                   # 能打补丁的游戏（Steam + deckkit 自己装的两种）
deck patches add '<补丁.exe|文件夹>'   # 解包 → 推断目标游戏 → 传上 Deck 入库
deck patches add '<补丁.exe>' --installer  # 带安装器的补丁：用游戏自己的 prefix 拉起向导（未实测）
deck patches mount <补丁>             # 挂载（覆盖游戏文件；不备份原文件）
deck patches unmount <补丁>           # 只告诉你还原办法（Steam 校验 / 回 Mac 重拷）
deck patches rm <补丁>                # 从库里删掉
```

**不备份被替换的原文件**（用户要求）：Deck 上只留几 KB 的 `manifest.tsv`（路径 + md5），
安装包和解包结果都不留 —— 要重挂时再选一次那个 exe（现场解包 + 临时传输 + 用完即删）。
覆盖用「临时文件 + mv」原子替换；还原走 Steam 的「验证文件完整性」。
（短别名：`ls` / `mount` / `unmount` / `rm`；完整用法 `deck patches help`。）

### `games` —— 把 Windows 游戏装到 Deck

```bash
deck games                            # 概览 + 已装的游戏
deck games add '<setup.exe>'          # 装安装包：切桌面模式 + 退 Steam → 拉起安装器 → 收尾
deck games add '.../游戏目录/game.exe' # 免安装游戏：**选主程序**（目录按它定位）→ 拷过去 → 收尾
deck games add '<主程序>' --root ..     # 主程序在 bin/ 里、数据在上一层：连上一层一起拷
deck games cover 'all'                 # 给库里的游戏生成封面：用 exe 自带的图标 + 标题（装完自动做）
deck games fix '<名字>'                # 点开始没反应？重挑主程序 + 挪开游戏自带的 Windows 版 DXVK
deck games shortcut <名字>             # 补登记（装完会自动登记）
deck games rm <名字>                   # 卸载：Steam 条目 + 游戏本体（目录/prefix），一次清掉
```

两条路都**自动登记进 Steam「非 Steam 游戏」**。是安装包还是免安装游戏，服务自己判断
（名字像 setup/install，或文件里有 NSIS/Inno 指纹 → 安装包；否则按绿色版：拷它所在的一整层）。
装安装包时除了"安装器里点下一步"全自动：会话准备（Game Mode 就切桌面、Steam 在跑就退出）、
解析桌面会话的 `DISPLAY`/`XAUTHORITY`、关掉会崩的 Xalia、前后快照 diff、挑出主程序 →
写 `run.sh` + 桌面菜单项 + 记录。**免安装**把这一大半绕掉了：没有安装器，就不用切会话、
不用开窗口、没有前后快照和"装完再找主程序"的收尾 —— 拷完直接在目录里挑主程序，
照样写 `run.sh` + 记录 + Steam 条目。详见 [SERVICE.md](services/games/SERVICE.md)。

## 它是怎么来的（vibe coding）

这个仓库是 **vibe coding** 的产物：代码主要由 AI（**DeepSeek V4.1**）在对话里写，
人负责定方向、在真实的 Steam Deck 上验收、把踩到的坑写回文档。

于是你会看到：

- 满篇「实测踩过」的注释 —— 那些都是真撞过的：bash 3.2 里 `$VAR` 紧跟全角字符会报
  `unbound variable`；Proton 的 Xalia 在非 Steam 上下文必崩（窗口永不出现）；
  Steam 退出时会把 `shortcuts.vdf` 清成 0 字节；macOS 的 `bsdtar` 会往 tar 里塞
  AppleDouble；`printf %q` 会把路径里的 `~` 包进 `$'...'` 让它不再展开……
- 以「能用 + 好排查」为先的结构，不求漂亮；该失败的地方**明确报错**，不静默丢结果。
- 不少地方明显是为一个人的环境定制的（路径、主机名、网段、游戏目录名），照着改就行。

**没有自动化测试** —— 每个服务的 `SERVICE.md` 里记着实测过程、已知边界和设计原因，
那是这个项目质量的主要来源；改动请照着 [`docs/约定.md`](docs/约定.md) 末尾的
《改动纪律》来（先想连带影响，改完实测那条路径）。

---

## 设计取舍

| 选择 | 原因 |
|---|---|
| **只碰用户态**，不改只读系统层 | SteamOS 大版本更新会重置只读层，用户态的东西活得更久 |
| **NFS 优先于 SMB** | `nfs-utils` 是官方预装包；Samba 要解锁只读层 + pacman，更新就没了 |
| **服务放 `~/deckkit/services/<名字>/`** | 和 Mac 侧结构对称，一眼知道哪个文件属于哪个服务 |
| **入口必须实现 `status` 且首行是摘要** | `deck` 概览和菜单栏都靠这一行，保证「加服务即自动出现在总览里」 |
| **`/etc` 里的东西一律用 provision 脚本重建** | SteamOS 更新会清掉 `/etc`，脚本幂等，重跑即可 |
| **菜单栏探测全在后台 + 带超时** | 主线程做同步网络调用会把菜单栏卡死 |
| **需要人敲键盘的步骤都从 Mac 发起** | Deck 没有键盘鼠标 |

---

## 环境要求

- **Mac**：macOS 11+ · Xcode 命令行工具（编菜单栏 App 用）· 已开「远程登录」（若要 Deck 反向连 Mac）
- **Deck**：SteamOS 3.x · 已开 SSH · `deck` 用户有免密 sudo（`/etc/sudoers.d/zz-deck-nopasswd`）
- **网络**：同一局域网，mDNS 可用（`steamdeck.local`）

---

## 版本控制

deckkit 根目录是一个 git 仓库（框架与各服务定义都在里面）：

```bash
cd ~/PycharmProjects/deckkit
git status
```

忽略列表：`_archive/`、`menubar/DeckKit.app/`、`.DS_Store`、`.idea/`。

---

## 归档

`_archive/` 放着已经退役的东西（原 `backup` 服务的部署包），
确认不再需要就可以整个删掉。

---

## 许可

MIT，见 [LICENSE](LICENSE)。
