# Steam Deck 上的 Windows 游戏：装 → 进 Steam 列表 → 卸载

入口只有一个 `deck games add <你选中的那个文件/目录>`，**是安装包还是免安装游戏，服务自己判断**：

| 你给的 | 判断 | 流程 |
|---|---|---|
| 安装包（`setup.exe`、Inno、NSIS…） | 名字里有 setup/install，**或**文件里有安装器指纹（NSIS/Inno/InstallShield…） | 准备会话（切桌面模式 + 退出 Steam）→ Proton 拉起安装器（你点"下一步"）→ 前后快照对比 → 生成启动脚本 → **自动登记进 Steam** |
| 免安装游戏（**你选中它的主程序 `game.exe`**） | 两条都不成立 | 把**主程序所在的那一层**拷到 Deck（`--root ..` 可以连上一层一起拷）→ 生成启动脚本 → **自动登记进 Steam**（没有安装器，就不切会话、不开窗口、没什么可等） |

```bash
deck games                            # 概览 + 已装的游戏
deck games add '<setup.exe>'          # 装安装包（向导窗口出现在 Deck 上，你点完成）
deck games add '<游戏目录>/game.exe'   # 免安装：**选主程序**（游戏目录按它定位）→ 拷过去 + 登记
deck games add '<主程序>' --root ..     # 主程序在 bin/ 里、数据在上一层：连上一层一起拷
deck games ls                         # 只列已装的
deck games shortcut <名字>             # 补登记（装完会自动做）
deck games rm <名字>                   # 卸载：Steam 条目 + 游戏本体（目录/prefix），一次清掉
```

菜单栏点 `games` 走 `pick`：弹文件选择器（安装包 / 游戏主程序 / 整个目录都能选）→ `add`。
判错可以改判：`--portable`、`--installer`；免安装游戏主程序挑错了用 `--exe <相对路径>`。
其它：`protons`（看 Deck 上的 Proton）、`shortcut-check`（`shortcuts.vdf` 无损自检）、
`clean`（清残留记录）、`help-all`（完整用法）。

## 流程（安装包）

| 环节 | 做法 |
|---|---|
| 会话准备 | 不在桌面模式 → `steamosctl switch-to-desktop-mode` 并等 plasmashell；Steam 在跑 → 先 `steam -shutdown`，20 秒不退再强杀（强杀常把 `shortcuts.vdf` 清成 0 字节 → 自动从备份恢复）。幂等 |
| appid / prefix | appid = `crc32('"<启动脚本路径>"+名字) \| 0x80000000`（和 Steam 给非 Steam 快捷方式算的一致）；prefix = `steamapps/compatdata/<appid>`，**先建好再装** |
| 显示会话 | 从桌面会话进程里读出真正的 `DISPLAY` / `XAUTHORITY` —— ssh 里两个都没有，硬写 `DISPLAY=:0` 会 "Authorization required"，窗口根本开不出来 |
| 跑安装器 | `proton run setup.exe`，且**必须关掉 Xalia**（`PROTON_USE_XALIA=0`，否则 `Unhandled exception in Xalia` → 崩溃、窗口从不出现）；输出写日志文件，不继承 ssh 管道 |
| 收尾 | 前后快照 diff → 在 prefix 里挑出主程序 → 写 `run.sh`（内置 prefix + Proton 版本）→ 写 `~/.local/share/applications/deckkit-<slug>.desktop`（名字/图标取自安装器）→ 记录 `store/<slug>/meta.tsv`。**找不到主程序就停手报错**（只落了运行库的更新器式安装器）<br>`find-game-exe` 的排除项只按 **prefix 内部**的路径匹配（例如 `drive_c/Program Files*/Steam/`）—— 不要写 `/Steam/`，那会匹配上 `~/.steam/steam/steamapps/…` 而把所有 exe 滤光（踩过） |
| 拉起安装器 | `gctl run` **是阻塞调用**：它一直等到安装器进程退出（你点完 Finish / 关掉窗口）才返回 → 返回即收尾，**不需要任何"探测安装器状态"的循环**（曾经为此写了一整套判据，纯属多余）。中途 Ctrl-C 只置标志不退出，**照样走收尾**（安装往往已经完成） |
| Steam 条目 | 收尾后**自动**写（`--no-shortcut` 跳过；也可单独跑 `deck games shortcut <名字>`）：写 `userdata/*/config/shortcuts.vdf`（二进制 KeyValues）。写之前做「解析→回写=原文」的**字节级自检** + 备份，并要求 Steam 未运行（命令自动处理会话） |
| 封面 | 紧接着**自动**做（`--no-cover` 跳过，或事后 `deck games cover <名字>`）：从主程序 exe 抠图标 → 在 Mac 上渲染 → 往 Steam 的 grid 目录写全套 5 个文件。见下面《封面》一节 |

## 流程（免安装 / 绿色版）

内核完全一样（appid / prefix / `run.sh` / Steam 条目），去掉的正是"装"那一半：

| 环节 | 做法 |
|---|---|
| 定位游戏目录 | **你选的主程序在哪儿，游戏目录就是哪一层**（不用猜）。一个目录里常有好几个 exe（汉化版/原版/不同版本/`UnityCrashHandler32.exe`），「按体积挑」猜错是必然 —— 实测 MyGame3 就是这么装错的。`--root ..` 可以往上一层（主程序在 `bin/`、数据在外面的情况） |
| 选中就判定 | 名字像 `*CrashHandler*`/`unins*`/`setup*`/redist → **直接拒绝**；同层还有别的 exe → 提示「同目录还有 X，确认跑的是这个」；exe < 32KB（引导器）→ 提醒；上一层看着有 `data/`/`*_Data/`/`*.xp3`/`package.json` → 提示 `--root ..`（都是提醒，不拦你） |
| 拷到 Deck | `tar \| ssh tar -x`（rsync 在 mac/Deck 版本不一致时会翻车）。落 `~/.local/share/deckkit/games/<slug>/game/` —— 和 `run.sh` 同一目录，于是 `deck games rm` 里那条 `rm -rf` 就把游戏本体一起删了，不留残渣 |
| 拷完复核 | 用**改进后的排除规则**在拷过去的目录里再挑一遍：挑出来的 ≠ 你选的 → 明确告诉你「按规则会挑 Y，起不来就 `deck games fix <名字> --exe Y`」（这就是「选错了也能救」那一步） |
| macOS 垃圾 | 两个开关都要：`COPYFILE_DISABLE=1`（不加的话 bsdtar 会给每个带 xattr 的文件附一份 AppleDouble `._名字`，.DS_Store 全排除掉也照样落一地）＋ `--no-xattrs`（不加的话 Deck 的 GNU tar 对每个文件刷一行 `Ignoring unknown extended header keyword`，879M 刷出十几万行） |
| dir slug | 目录名允许中日文（`mygame`），显示名原样进 Steam |
| 主程序 | `gamectl find-game-exe --dir <游戏目录>`：排除 unins/setup/redist/… 后取最大的 exe；你点的就是 exe 的话直接用它 |
| prefix | 照旧先建一个**空的**：第一次启动时 Proton 自己初始化（日志 `Upgrading prefix from None to 11.0-100`） |
| 会话 | 只有"写 `shortcuts.vdf`"这一步需要 Steam 不在跑（和 `shortcut` 共用），拷贝、挑主程序都不需要 |
| 封面 | 和安装包那条一样**自动**做（`--no-cover` 跳过）：抠 exe 图标 → 渲染 → 写 grid 全套 5 个 |

`run.sh` 是**Linux 脚本**，Steam 当原生程序跑，脚本自己带好 `STEAM_COMPAT_DATA_PATH` 和 Proton ——
所以那条快捷方式**不要**设"强制使用 Proton"，也完全不需要写 `config.vdf`。

## 实测

```
OpenTTD 14.1（8MB NSIS 安装包）：
  deck games add ~/Desktop/openttd-14.1-windows-win64.exe --silent --name OpenTTD
    → 名字里没有 setup，靠**指纹**认出是 NSIS 安装包（只按名字会误判成绿色版）
    → prefix compatdata/2329061293 + drive_c/Program Files/OpenTTD/openttd.exe
    → run.sh ✓ 桌面菜单项 ✓ 记录 ✓ Steam 条目 ✓，切回 Gaming Mode 点开始能玩 ✓

MyGame ver1.01（SRPG Studio，878M 免安装目录）：
  deck games add '.../MyGame/game.exe'
    → 判定"不像安装包" → 按免安装办：879M 走 tar|ssh 到
      ~/.local/share/deckkit/games/mygame/game/（2799 个文件，源目录也是 2799，一个不多一个不少）
    → slug mygame，appid 3608512011，Proton 11.0，空 prefix，game.exe 自动选中
    → run.sh ✓ meta.tsv（portable=1、size=879M）✓ Steam 条目 ✓
    → 全过程 36 秒（含 879M 拷贝）
  真能跑（按 Steam 的默认环境：不设 PROTON_LOG 即 WINEDEBUG=-all、DXVK_LOG_LEVEL=none）：
    run.sh → game.exe 15.9% CPU + 窗口「MyGame」1024x768 ✓
```

## 封面（`deck games cover`）

Steam 给「非 Steam 快捷方式」的封面就是往它自己的 grid 目录里丢文件 —— 不用碰 Steam 的任何配置：

一次写全套 5 个（Deck 主页那条**横版卡**用的是 `_hero.png` + `_logo.png`，只写前两个时那条是空的 —— 实测踩过）：

| 文件 | 用途 | 尺寸 |
|---|---|---|
| `userdata/<id>/config/grid/<appid>p.png` | 库里的大封面（Gaming Mode 的网格就是它） | 600×900 |
| `userdata/<id>/config/grid/<appid>.png` | 横版「网格图」 | 920×430 |
| `userdata/<id>/config/grid/<appid>_header.jpg` | 列表头图 | 460×215 |
| `userdata/<id>/config/grid/<appid>_hero.png` | **主页「最近游戏」横版卡的底图**（不写字，留空给 Steam 压字标） | 1920×620 |
| `userdata/<id>/config/grid/<appid>_logo.png` | 压在 hero 上的**透明字标**（游戏名） | 1280×720 |

```bash
deck games cover <名字|all>             # 默认：主程序自带图标居中 + 背景按图标主色上色 + 标题
deck games cover <名字> --icon-fill     # 把图标铺满整张
deck games cover <名字> --image 图.png   # 拿别的图铺满（居中裁切 + 压暗 + 标题）
deck games cover <名字> --find          # 在游戏目录里找像 title/cover/box/package/jacket/logo 的图铺满
deck games cover <名字> --no-icon       # 不要图标，退回纯排版封面（深色渐变 + 标题）
deck games cover <名字> --reicon        # 丢掉缓存的图标，重新从 exe 抠一次
```

- **装完自动做**：`deck games add` 登记完 Steam 条目就顺手写封面（`--no-cover` 跳过）。
- **图标从主程序 exe 里抠**：`deck/peicon.py` 纯 Python 解析 PE 资源
  （`RT_GROUP_ICON` 描述 + `RT_ICON` 数据，256px 那种直接存 PNG、老的 DIB 自己解位深），
  取**最大的一张**，缓存在 `store/<slug>/icon.png`。Deck 上没有 icoutils 也不用装 —— 不需要。
- **图在 Mac 上渲染**（`mac/cover.swift`，Deck 上没有 AppKit）：背景渐变按图标的主色上色
  （不是一坨灰），图标居中放一枚（小图标不硬拉大，64px 的放到 170px 为止）；短名字
  （OpenTTD）保持一行、长中文标题自动折行放大填满版面。
- `--find` 只认名字里带 `title/cover/box/package/jacket/logo` 的图，**不会**去抓
  `bgimage/` 那种 CG —— 自动挑到不该露的图，比没封面更糟。想用哪张，`--image` 明说。
  （注意：**exe 自带的图标本身就是游戏作者放的图**，个别游戏会是很露骨的那种 ——
  那种就用 `--no-icon` 或 `--image` 换掉。）
- 覆盖之前会把**用户自己放过的**封面留一份 `<appid>p.png.deckkit-bak`（靠 store 里的
  `cover.own` 标记区分"是不是 deckkit 写的"，所以重新生成时不会反复备份自己的图）；
  `deck games rm` 会把封面、备份、缓存的图标和标记一起清掉。
- **Steam 正在跑的话，要重启 Steam（或切一次 Gaming/桌面模式）才看得到新封面。**

## 终端里的游戏管理（方向键操作）

```bash
deck games        # 终端里 = 交互列表：精简服务状态 + 游戏列表，方向键操作
deck games ls     # 永远只列（脚本/管道里用这个）
deck brief        # 只要那份精简服务状态（一个服务一行）
deck status       # 完整状态（全量 dump）
```

- **只画两样东西**：顶上那份精简服务状态（每服务一行），下面游戏列表 —— 不在终端里堆全量信息。
- **像 htop 那样在"备用屏"里画**：画面定长、原地重画，退出后终端恢复原样（不往 scrollback
  里堆一帧帧列表）；终端太矮时列表自动开窗口分页，用「↑ 上面还有 N 项 / ↓ 下面还有 N 项」提示。
- 宽度按"一个字符最坏占 2 列"保守截断（中文不会被切半个字），宽窄都自适应。
- 键位：`↑`/`↓` 选择，**回车 = 卸载**（会再问一次 y/N），`c` 重做封面，`f` 维修，`r` 刷新，`q` 退出。
- 卸载前会提示：会顺带退出 Steam（要写 `shortcuts.vdf`），需要的话还会切到桌面模式。
- 交互期间**全程关回显**（问 y/N 时也关着、把按的键自己显示出来），等按键都带超时 ——
  方向键不会变成 `^[[A`，也不会卡在某个提示上出不来。跑外部命令时先退出备用屏、按任意键回来。
- 异常退出（`q` / Ctrl-C / 中途报错）都会把**回显 + 光标 + 备用屏**还原（EXIT/INT/TERM 三个 trap，
  状态放全局变量，避免 `set -u` 把还原那步打断）。真被外部因素搞乱了：敲 `reset` 回车即可。
- stdin/stdout 不是终端时（`deck games | cat`、脚本里）自动退回原来的概览，不会画界面。
- 菜单栏那条「游戏管理（终端 · 方向键操作）」调的就是它；「完整状态（终端）」是另一条。

## 手柄布局：让右摇杆当鼠标（`deck games pad`）

非 Steam 游戏大多没有手柄支持，界面只能靠触控板 —— 这不是游戏的问题，是 **Steam Input**
那一层没配好。改的是 Steam 的手柄布局，**不用碰游戏本体**：

```bash
deck games pad --list                    # 看每个游戏现在用的是什么布局（只读，Steam 跑着也能看）
deck games pad <名字|all>                # 装「仅鼠标」布局（默认）
deck games pad <名字> -t gamepad+mouse   # 换模板：mouse / gamepad+mouse / wasd / webbrowser / fps / joystick / touchscreen
deck games pad <名字> --dry-run          # 只生成不落地（写 ~/deckkit-pad-dryrun，方便先看）
deck games pad <名字> --rm               # 撤掉，回到 Steam 默认（有备份就还原备份）
```

- **配置存在哪**：`~/.local/share/Steam/steamapps/common/Steam Controller Configs/<steamid>/config/<key>/controller_neptune.vdf`，
  并在同目录 `configset_controller_neptune.vdf` 里用 `"<key>" { "autosave" "1" }` 登记。
- **`<key>` 的规则**：快捷方式名字转小写 + 去掉 `.`（实测验证：`MyGame2 V2.0版+…` →
  `MyGame2 v20版+…`、`UkiyoGensoEnnichi` → `ukiyogensoennichi`，都能对上机器上已有的目录）。
  非 Steam 快捷方式用**名字**当 key 而不是 appid —— 因为改名以后 appid 会变。
- **映射本体**直接取 Steam 自带的 Deck 模板（`~/.steam/steam/controller_base/templates/controller_neptune_*.vdf`）；
  header 字段（creator/progenitor/url/controller_caps…）照 Steam 自己写的那份生成，
  实测和 Steam 自己的配置文件**字段名逐行一致**；行尾统一成 LF（模板是 CRLF、Steam 写出来是 LF）。
- **真写必须让 Steam 停着**（它会把这些配置缓存在内存里、退出时回写），命令会自动处理会话
  （退出 Steam、需要时切桌面模式）；`--list` / `--dry-run` 不受影响。
- 装完**重启 Steam（或切一次模式）**，在游戏页面 → 手柄图标（控制器布局）里能看到布局名。
  界面里也能直接改：模板 → 「仅鼠标」/「游戏手柄 + 鼠标」→ 应用，效果和本命令一致。

Deck 上两个模板的实际映射（解析 `controller_neptune_*.vdf` 得到）：

| | 仅鼠标 `mouse` | 游戏手柄 + 鼠标 `gamepad+mouse` |
|---|---|---|
| 右摇杆 | **鼠标移动**（`joystick_mouse`） | 鼠标移动 |
| 右触控板 | **绝对式鼠标**（`absolute_mouse`） | 鼠标移动 |
| A / X | 鼠标左键 / 右键 | `xinput A` / `X` |
| B | Esc | `xinput B` |
| 方向键 | 鼠标左键 / 右键（可当确认与返回） | `xinput dpad_*` |
| LB / RB | 滚轮上 / 下 | `xinput shoulder_*` |
| 扳机 | 左 / 右键 | 左 / 右键 |

**怎么选**：游戏完全不认手柄（视觉小说、点选 UI）→ `mouse`；游戏认手柄但界面要鼠标
（Unity 小游戏、部分 RPG）→ `gamepad+mouse`；要靠键盘走的界面 → `wasd`。

## 点开始没反应？先跑 `deck games fix`

实测两个坑，都是"Steam 里点了开始，什么都没发生"，`fix` 一次收拾：

| 坑 | 症状 / 证据 | fix 做什么 |
|---|---|---|
| **主程序挑错了**：`find-game-exe` 按"最大的 exe"挑，而 Unity 游戏目录里的 `UnityCrashHandler32.exe`（923KB）比真主程序（640KB）还大 | 启动的是崩溃处理器 → 点开始**彻底没反应**（进程一闪而过） | 排除表加了 `crashhandler / crashreport / steamerrorreporter` 等；`fix` 重挑并重写 `run.sh` + `meta.tsv` |
| **repack 自带 Windows 版 DXVK**：游戏目录里的 `d3d11.dll`（2.6MB，配 `ShaderFixes/`） | Wine 的 dll 搜索顺序是"程序目录优先" → 这份 Windows dll 被加载 → Proton 下必崩（`Player.log`：`GfxDevice: creating device client` 之后 `Crash!!!` + 访问违例） | 把 `d3d11/dxgi/d3d10core/d3d12/d3d9.dll` 里 **>200KB 的**改名成 `<名字>.deckkit-off`（可逆），让 Proton 自带 DXVK 接管 |

```bash
deck games fix <名字>              # 也支持 all
deck games fix <名字> --exe 子目录/主程序.exe   # 自己指定主程序
```

- **`WINEDLLOVERRIDES=d3d11=b` 没用** —— Proton 会自己重写这个环境变量（实测），所以只能挪文件。
- 挪开的是文件、不是删除；想改回来把 `.deckkit-off` 后缀去掉即可。
- 主程序变了的话，图标/封面会**自动重做**（`--no-cover` 跳过）。

## 已知边界

- **Deck 要在桌面模式**才能看到安装向导 —— 服务会自动切过去，不用你手动切。
- **更新器式安装器**：有的安装器只落 .NET/运行库 + 它自己的 updater（实测 GameSir Connect
  就是这样：595 个新文件里没有主程序）。`finish` 会报"没找到主程序"并停手 —— 这时别登记 Steam 条目。
- **免安装拷的是「主程序所在那一层」**：数据在上一层（比如 exe 在 `bin/` 里、资源在 `bin/..`）
  时加 `--root ..`，或者干脆选上层那个 exe。现在选**文件夹**会被拒绝（除非显式 `--from-dir`）——
  一个目录里可能有好几个版本，让程序猜不如你指。
- **卸载会把 Steam grid 里的封面也清掉**（`<appid>p.png` / `.png` / `_header.jpg` /
  `_hero.png` / `_logo.png`，连用户自己的 `.deckkit-bak` 一起）—— 不然会留一堆 appid 已经不存在的
  孤儿图；要留封面就先 `cp` 出来。
- **卸载会连游戏目录一起删** —— 免安装游戏的存档常在游戏目录里（SRPG Studio 是 `Save/`），
  要留就先自己拷出来。装 exe 的游戏存档在 prefix 里，同理。
- **别用日志行数判断"游戏起没起来"**：不设 `PROTON_LOG` 时 Proton 会把 `DXVK_LOG_LEVEL` 设成
  `none`，DXVK 一行都不打（实测：明明已经渲染出窗口、15% CPU，日志里只有 2 行）。要看窗口/CPU。
- **`steam -applaunch <非 Steam 快捷方式的 appid>` 在本机不工作**（`AppError_9`，连已知能玩的
  OpenTTD 也一样）—— 别拿它当验证手段，验证就直接跑 `run.sh`，或去库里点。
- **从 ssh 手工拉起 `run.sh` 要带桌面会话的环境**（`LANG`、`WAYLAND_DISPLAY`、`DISPLAY`、
  `XAUTHORITY`…；从 plasmashell 的 `/proc/<pid>/environ` 里取）。Steam 拉起时天然就有，
  `run.sh` 里还给 `LANG` 兜了个底。
- **反作弊类游戏（米哈游等）**：装的部分一样，但官方客户端的反作弊在 Proton 下跑不起来 ——
  社区方案是打反作弊补丁的启动器（`an-anime-team` 那套：原神 An Anime Game Launcher、
  星铁 the-honkers-railway-launcher、绝区零 sleepy-launcher），且每次游戏更新后要重打，
  涉及厂商 ToS/封号风险。本服务目前只做"装 + 配置 + 登记"。
