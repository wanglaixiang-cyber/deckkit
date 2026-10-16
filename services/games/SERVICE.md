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
deck games fonts                       # 汉化游戏中文字形（Wine/Proton 层 + fontconfig 别名）—— 见《中文显示》一节
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
| 封面 | 紧接着**自动**做（`--no-cover` 跳过，或事后 `deck games cover <名字>`）：取游戏自带图标（`package.json` 的 `window.icon`；没有才抠 exe）→ 在 Mac 上渲染 → 往 Steam 的 grid 目录写全套 5 个文件。见下面《封面》一节 |

## 流程（免安装 / 绿色版）

内核完全一样（appid / prefix / `run.sh` / Steam 条目），去掉的正是"装"那一半：

| 环节 | 做法 |
|---|---|
| 定位游戏目录 | **你选的主程序在哪儿，游戏目录就是哪一层**（不用猜）。一个目录里常有好几个 exe（汉化版/原版/不同版本/`UnityCrashHandler32.exe`），「按体积挑」猜错是必然 —— 实测 轮回电车 就是这么装错的。`--root ..` 可以往上一层（主程序在 `bin/`、数据在外面的情况） |
| 选中就判定 | 名字像 `*CrashHandler*`/`unins*`/`setup*`/redist → **直接拒绝**；同层还有别的 exe → 提示「同目录还有 X，确认跑的是这个」；exe < 32KB（引导器）→ 提醒；上一层看着有 `data/`/`*_Data/`/`*.xp3`/`package.json` → 提示 `--root ..`（都是提醒，不拦你） |
| 拷到 Deck | `tar \| ssh tar -x`（rsync 在 mac/Deck 版本不一致时会翻车）。落 `~/.local/share/deckkit/games/<slug>/game/` —— 和 `run.sh` 同一目录，于是 `deck games rm` 里那条 `rm -rf` 就把游戏本体一起删了，不留残渣 |
| 拷完复核 | 用**改进后的排除规则**在拷过去的目录里再挑一遍：挑出来的 ≠ 你选的 → 明确告诉你「按规则会挑 Y，起不来就 `deck games fix <名字> --exe Y`」（这就是「选错了也能救」那一步） |
| macOS 垃圾 | 两个开关都要：`COPYFILE_DISABLE=1`（不加的话 bsdtar 会给每个带 xattr 的文件附一份 AppleDouble `._名字`，.DS_Store 全排除掉也照样落一地）＋ `--no-xattrs`（不加的话 Deck 的 GNU tar 对每个文件刷一行 `Ignoring unknown extended header keyword`，879M 刷出十几万行） |
| dir slug | 目录名允许中日文（`Some Game 5ver1-01`），显示名原样进 Steam |
| 主程序 | `gamectl find-game-exe --dir <游戏目录>`：排除 unins/setup/redist/… 后取最大的 exe；你点的就是 exe 的话直接用它 |
| prefix | 照旧先建一个**空的**：第一次启动时 Proton 自己初始化（日志 `Upgrading prefix from None to 11.0-100`） |
| 会话 | 只有"写 `shortcuts.vdf`"这一步需要 Steam 不在跑（和 `shortcut` 共用），拷贝、挑主程序都不需要 |
| 封面 | 和安装包那条一样**自动**做（`--no-cover` 跳过）：取游戏自带图标（没有才抠 exe）→ 渲染 → 写 grid 全套 5 个 |

`run.sh` 是**Linux 脚本**，Steam 当原生程序跑，脚本自己带好 `STEAM_COMPAT_DATA_PATH` 和 Proton ——
所以那条快捷方式**不要**设"强制使用 Proton"，也完全不需要写 `config.vdf`。

## 实测

```
OpenTTD 14.1（8MB NSIS 安装包）：
  deck games add ~/Desktop/openttd-14.1-windows-win64.exe --silent --name OpenTTD
    → 名字里没有 setup，靠**指纹**认出是 NSIS 安装包（只按名字会误判成绿色版）
    → prefix compatdata/2329061293 + drive_c/Program Files/OpenTTD/openttd.exe
    → run.sh ✓ 桌面菜单项 ✓ 记录 ✓ Steam 条目 ✓，切回 Gaming Mode 点开始能玩 ✓

Some Game 5 ver1.01（SRPG Studio，878M 免安装目录）：
  deck games add '.../Some Game 5ver1.01/game.exe'
    → 判定"不像安装包" → 按免安装办：879M 走 tar|ssh 到
      ~/.local/share/deckkit/games/Some Game 5ver1-01/game/（2799 个文件，源目录也是 2799，一个不多一个不少）
    → slug Some Game 5ver1-01，appid 3608512011，Proton 11.0，空 prefix，game.exe 自动选中
    → run.sh ✓ meta.tsv（portable=1、size=879M）✓ Steam 条目 ✓
    → 全过程 36 秒（含 879M 拷贝）
  真能跑（按 Steam 的默认环境：不设 PROTON_LOG 即 WINEDEBUG=-all、DXVK_LOG_LEVEL=none）：
    run.sh → game.exe 15.9% CPU + 窗口「Some Game 5ver1.01」1024x768 ✓
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
deck games cover <名字|all>             # 默认：游戏自带图标居中 + 背景按图标主色上色 + 标题
deck games cover <名字> --icon-fill     # 把图标铺满整张
deck games cover <名字> --image 图.png   # 拿别的图铺满（居中裁切 + 压暗 + 标题）
deck games cover <名字> --find          # 在游戏目录里找像 title/cover/box/package/jacket/logo 的图铺满
deck games cover <名字> --no-icon       # 不要图标，退回纯排版封面（深色渐变 + 标题）
deck games cover <名字> --reicon        # 丢掉缓存的图标，重新取一次
```

- **装完自动做**：`deck games add` 登记完 Steam 条目就顺手写封面（`--no-cover` 跳过）。
- **图标优先用「游戏自己的」，抠 exe 只当兜底**（顺序见下）。原因是一个实测踩到的坑：
  **NW.js 打包的 RPG Maker MV 游戏，`Game.exe` 是引擎的通用启动器**，资源段里嵌的是
  **RPG Maker MV 的官方标志**（戴学士帽拿剑的 Q 版小人），不是这款游戏的美术。
  实测 Some Game 1：exe 抠出 256×256 的引擎标志，而游戏真正的立绘在 `www/icon/icon.png`
  （128×128，角色图），md5 完全不同 —— 封面就挂了个引擎图标上去。
  **所有 NW.js 的 MV 游戏都会中招**（含正常那个 Some Game 14）。
  取图顺序：
  1. `package.json` 的 `window.icon`（NW.js 的官方约定，通常就是 `www/icon/icon.png`）
  2. 兜底约定的 `www/icon/icon.png` / `icon.png`（≥1KB 才算，避开占位小图）
  3. 都没有 → 才走 `deck/peicon.py` 从 exe 资源段抠
- **`deck/peicon.py`**：纯 Python 解析 PE 资源（`RT_GROUP_ICON` 描述 + `RT_ICON` 数据，
  256px 那种直接存 PNG、老的 DIB 自己解位深），取**最大的一张**，缓存在 `store/<slug>/icon.png`。
  Deck 上没有 icoutils 也不用装 —— 不需要。
- **图在 Mac 上渲染**（`mac/cover.swift`，Deck 上没有 AppKit）：背景渐变按图标的主色上色
  （不是一坨灰），图标居中放一枚（小图标不硬拉大，64px 的放到 170px 为止）；短名字
  （OpenTTD）保持一行、长中文标题自动折行放大填满版面。
- `--find` 只认名字里带 `title/cover/box/package/jacket/logo` 的图，**不会**去抓
  `bgimage/` 那种 CG —— 自动挑到不该出现在主界面的图，比没封面更糟。想用哪张，`--image` 明说。
  取到的图不满意就用 `--no-icon`（纯排版）或 `--image <图>` 换掉，就这么简单。
- 换过取图顺序之后，**老封面要重生成**才生效：`deck games cover <名字> --reicon`。
- 覆盖之前会把**用户自己放过的**封面留一份 `<appid>p.png.deckkit-bak`（靠 store 里的
  `cover.own` 标记区分"是不是 deckkit 写的"，所以重新生成时不会反复备份自己的图）；
  `deck games rm` 会把封面、备份、缓存的图标和标记一起清掉。
- **Steam 正在跑的话，要重启 Steam（或切一次 Gaming/桌面模式）才看得到新封面。**

## 终端里的游戏管理（方向键操作）

```bash
deck games        # 终端里 = 交互列表，方向键操作（管道/脚本里自动退回概览）
deck games ls     # 永远只列（脚本/管道里用这个）
deck brief        # 精简服务状态（一个服务一行）
deck status       # 完整状态（全量 dump）
```

- **版面**：标题 / 分隔线 / 游戏列表 / 分隔线 / 提示。**不再往列表里塞服务状态** ——
  那是另一件事（`deck brief`），塞进来既占 4 行、每次刷新还要多跑一遍 4 个服务的
  `status`（约 4 秒），想看服务状态直接敲 `deck`。
- **每行 = 安装日期 + 名字 + 大小**，默认按**安装日期正序**（旧的在上）。
  日期取自 `meta.tsv` 的 `installed_at`，没有就退回 store 目录的 mtime。
- **`s` 换排序**：日期 → 名称 → 大小 → 日期，当前方式直接写在提示行里。
  排序是**本地**做的（采集和排序分开），所以按 `s` 不会再问一次 Deck。
  三个键里「大小」不能拿 `sort` 排 —— `380M`/`3.1G` 是带单位的字符串，
  按文本比会把 `1.2G` 排在 `380M` 前面；实际换算成字节、大的在前。
  换排序后**选中项会跟住**（按 slug 找新位置），光标不会自己跳到别的游戏上。
- **对齐是按显示列算的**，不是字符数：中日文一个字占 2 列，所以名字用 python
  按 `east_asian_width` 截断+补齐（组合字符算 0 列）——
  不然中日文行会整片错位（这正是以前列表"没对齐"的原因）。
- **键位全是方向键**：

  | 键 | 收起时 | 展开时 |
  |---|---|---|
  | `↑`/`↓` | 选条目（循环） | 收起并移到上/下一条 |
  | `←`/`→` | 翻页（一屏） | 选命令 |
  | 回车 | 展开该条目 | 执行选中的命令 |
  | `PageUp`/`PageDown` | 翻页 | — |
  | `Esc` | — | 收起 |
  | `s` | 换排序（日期 → 名称 → 大小） | — |
  | `r` / `q` | 刷新 / 退出 | 同左 |

  另有 `j`/`k`/`h`/`l` 四个 vim 键做同样的移动。
- **展开行缩进一层放命令**（卸载 / 封面 / 维修），`←`/`→` 选、回车执行。
  卸载仍会再问一次 y/N（不可恢复，且会顺带退出 Steam）。
- **像 htop 那样在"备用屏"里画**：每帧先 `\033[H\033[J` 回左上清屏再整屏重画 ——
  **顺序不能反**，反了的话 `\033[J` 是从旧光标位置清到屏尾，清不掉上一帧多出来的行，
  画面一变矮（收起展开行、列表变短）就会留下几行残影。
- 交互期间**全程关回显**（问 y/N 时也关着、把按的键自己显示出来），等按键都带超时 ——
  方向键不会变成 `^[[A`，也不会卡在某个提示上出不来。跑外部命令时先退出备用屏、按任意键回来。
- 异常退出（`q` / Ctrl-C / 中途报错）都会把**回显 + 光标 + 备用屏**还原（EXIT/INT/TERM 三个 trap，
  状态放全局变量，避免 `set -u` 把还原那步打断）。真被外部因素搞乱了：敲 `reset` 回车即可。
- stdin/stdout 不是终端时（`deck games | cat`、脚本里）自动退回原来的概览，不会画界面。
- 菜单栏那条「游戏管理（终端）」调的就是它；「完整状态（终端）」是另一条。

## 点开始没反应 / 起不来？先跑 `deck games fix`

实测四个坑，`fix` 一次全查（前两个是"点了开始什么都没发生"，后两个是"窗口起来了但用不了"）：

| 坑 | 症状 / 证据 | fix 做什么 |
|---|---|---|
| **主程序挑错了**：`find-game-exe` 按"最大的 exe"挑，而 Unity 游戏目录里的 `UnityCrashHandler32.exe`（923KB）比真主程序（640KB）还大 | 启动的是崩溃处理器 → 点开始**彻底没反应**（进程一闪而过） | 排除表加了 `crashhandler / crashreport / steamerrorreporter` 等；`fix` 重挑并重写 `run.sh` + `meta.tsv` |
| **repack 自带 Windows 版 DXVK**：游戏目录里的 `d3d11.dll`（2.6MB，配 `ShaderFixes/`） | Wine 的 dll 搜索顺序是"程序目录优先" → 这份 Windows dll 被加载 → Proton 下必崩（`Player.log`：`GfxDevice: creating device client` 之后 `Crash!!!` + 访问违例） | 把 `d3d11/dxgi/d3d10core/d3d12/d3d9.dll` 里 **>200KB 的**改名成 `<名字>.deckkit-off`（可逆），让 Proton 自带 DXVK 接管 |
| **NW.js 关了 GPU**：MZ 官方默认的 `chromium-args` 就有 `--disable-gpu`，再叠一个 `--disable-software-rasterizer`（实测见到的写法还是畸形的 `=0`）之后，Chromium 连**软件 WebGL 都没了** | 窗口正常打开，正中显示 `Error / Your browser does not support WebGL.`（RPG Maker MZ 用 PixiJS，硬要 WebGL，没有就只给这一行） | 从 `package.json` 的 `chromium-args` 里**只摘掉** `--disable-gpu` / `--disable-gpu-compositing` / `--disable-software-rasterizer*`，其余（含 `--no-sandbox`）一行不动；原文件备份 `package.json.deckkit-orig`。摘掉后走 ANGLE → Wine 的 D3D11 → DXVK |
| **macOS 中转留下的 NFD 文件名**：macOS 文件系统把名字存成 NFD（`ゾ` = `U+30BD` + `U+3099`），而游戏数据（`data/*.json`）里写的是 NFC（`U+30BE`） | 引擎按数据拼路径 → 404 → MZ 停在 `Failed to load audio/bgm/…`（实测：磁盘上叫 `Some Game 2BGM/A.D.END…`，数据要 `Some Game 2BGM/A.D.END…`）。**纯 ASCII 名字不受影响**，所以只挑带浊点的日文名犯，不看字节根本发现不了 | 跑 `deck/nfc-names.py` 把**整棵游戏目录**的名字规范化成 NFC（从最深的层往上改，先文件后目录），只改名字形式、不动内容；undo 表写在 deck 的 `/tmp/deckkit-nfc-undo.tsv` |

只想单独跑某一项：

```bash
deck games fix <名字> --nwjs-webgl   # 只查/修 WebGL 参数
deck games fix <名字> --nfc-names    # 只查/修 NFD 文件名
```

另外，**免安装游戏从 macOS 拷过来时，上传流程本身就会自动做一次 NFD→NFC**
（`tar` 解包后立刻规范化，报 `规范化 N 个文件名`）—— 上面那条 `--nfc-names` 是给
"早就装好、后来才发现"的游戏补的。踩过的具体案例：`source_dir` 是
`~/Desktop/…` 的那款 MZ 汉化版，磁盘上 135 个名字是 NFD，标题 BGM 直接 404。
（`patches` 服务的目录上传没有这一步。）

```bash
deck games fix <名字>              # 也支持 all
deck games fix <名字> --exe 子目录/主程序.exe   # 自己指定主程序
deck games fix <名字> --nwjs-canvas            # 老 NW.js 黑屏（有声无画）—— 见下一节
deck games fix <名字> --nwjs-canvas-undo       # 撤销上一条
```

- **`WINEDLLOVERRIDES=d3d11=b` 没用** —— Proton 会自己重写这个环境变量（实测），所以只能挪文件。
- 挪开的是文件、不是删除；想改回来把 `.deckkit-off` 后缀去掉即可。
- 主程序变了的话，图标/封面会**自动重做**（`--no-cover` 跳过）。

## 有声无画（黑屏）？RPG Maker MV + 老 NW.js

**症状**：音乐在放、按键有反应，**画面全黑**。最典型的形态是**开头出一帧封面，之后就黑**。

**原因**（实测 Some Game 1 坐实的）：**游戏本身没问题**。注入探针读页面内部状态，得到

```
SceneManager._scene = Scene_Map        ← 已进地图，不是卡在标题
SceneManager.isCurrentSceneStarted = true
$dataMap ok / $gamePlayer ok           ← 地图和玩家都正常
GameCanvas 1280x720，非黑像素 8.84%，中心像素 RGBA(69,57,82)  ← canvas 里画的是真画面
```

也就是 **canvas 渲染完全正常，但那一帧送不到窗口/合成器** → 屏幕黑，而音频/按键
（不走渲染路径）照常。第一帧偶尔能提交成功，于是表现为"封面闪一下然后全黑"。

**装的时候就能查出来**（判据全在文件布局上，零成本）：

| 判据 | 老 NW.js（危险） | 新 NW.js（正常） |
|---|---|---|
| `nw.pak` | 有 | 无 |
| `nw.dll` | **无** | 有 |
| `nw_100_percent.pak` | **无** | 有 |
| `ffmpegsumo.dll` | **有** | 无（并进 nw.dll 了） |
| `www/js/rpg_core.js` | 有（RPG Maker MV） | 有 |

实测对照：`Some Game 1`（老，黑屏）vs `Some Game 14`（新，正常）判据完全相反。
`deck games add` 装完会**自动检测并提示**（只提示，不拦、不改参数）：

> ⚠ 检测到「RPG Maker MV、老 NW.js、ffmpegsumo」—— 这类在 Proton 下有黑屏先例

**注意分寸**：这是**风险标签，不是结论** —— 老 NW.js 不一定黑屏（deckkit 里别的老引擎游戏就没事），
黑不黑是「老 NW.js × Proton × 合成路径」的组合结果。所以先跑一次看看，中招了再修：

```bash
deck games fix <名字> --nwjs-canvas
```

它**只改这一款游戏的** `package.json`（每游戏 play 目录独立，不动别人的 `run.sh`）：

| 改动 | 作用 |
|---|---|
| `main` 加 `?canvas` | RPG Maker MV 自己读（`rpg_core.js` 的 `isOptionValid`）→ 走 Canvas 渲染 |
| `chromium-args: --in-process-gpu --disable-gpu-vsync --ignore-gpu-blacklist` | 渲染与窗口同进程，少一次跨进程合成交接（卡住的就是这个交接） |

- **幂等**：重复跑不会把 `?canvas` 变成 `?canvas&canvas`。
- **可撤销**：改前留 `package.json.deckkit-orig`，`--nwjs-canvas-undo` 还原。
  只有当文件**确实是原版**时才留这份备份 —— 若 `package.json` 事先已被手改过，
  会明确告诉你"没有干净原版可备份"，而不是留一份假原版让 undo 假装能还原。
- **反例留档**（别把它们当成"修好了的原因"）：`--use-angle=d3d11` 和
  `--disable-frame-rate-limit` **这版 Chromium 41 不认**（binary 里搜不到，会被静默吞掉）；
  `--use-gl=swiftshader`（纯软件渲染）也**无效** —— 这恰好证明问题不在 GPU 路径。

## 中文显示不正常（方块 / 缺字 / 字距错乱）

**症状**：中文显示成空白或空心方块，被吃掉的往往是**简体特有字**
（头 / 开 / 结 / 戏 / 环 / 继 / 续 / 设）。日语部分正常、英文正常 —— 所以一眼看不出是字体问题。

实测（`Some Game 2 三重奏/交響曲/協奏曲/終曲`、`RJ00000000 鎮魂歌`）：

| 应当显示 | 实际显示 | 缺的字 |
|---|---|---|
| 从头开始 | `从 始`（中间两个空位） | 头 开 |
| 从继续开始 | `从 始` | 继 续 开 |
| 环境 | `境` | 环 |
| 结束游戏 | `束游` | 结 戏 |

**原因（一层压一层，实测链路）**

1. 这些游戏把字体名**写死在数据里**。SRPG Studio 系在 `data.dts` 的项目段里有一张
   UI 字体表（默认/标题/消息显示/… 全是 `MS Gothic`）；`終曲` 那张表是空的，引擎就退回
   **写死在 `game.exe` 里的 `Meiryo UI`**。
2. Proton 自带的 `files/share/fonts/msgothic.ttc` **不是 MS Gothic，而是 Ume-Gothic**
   —— 14963 个字形、只有 JIS，简体特有字一个都没有：
   ```
   $ python3 -c '…'-f 从新开始境束游戏结环设置头存档   →  从新·始境束游····置·存档
   ```
   prefix 里又完全没有 `Meiryo UI` 这个 family → 引擎拿不到字体，退到拉丁字体画豆腐块。
3. Wine 的 SystemLink 兜底链（`Tahoma` / `System` / `MS Shell Dlg` → `MSGOTHIC.TTC,MS UI
   Gothic`）指向同一个 Ume-Gothic；链里那条 `MSYH.TTC,Microsoft YaHei UI` 是**断的**
   （Proton 只放了 `msyh.ttf`，文件名对不上）→ 兜底也接不上。
4. **fontconfig 别名对这一类游戏没用**（下面的第一版修复就是踩了这个坑）：
   Deck 上 `fc-match "MS Gothic"` 明明已经指向 Noto CJK，游戏里照旧缺字 —— Wine 优先命中
   prefix 里**按文件名注册**的 `msgothic.ttc`，根本不走 fontconfig 的 pattern 匹配。
5. **改 prefix 里的字体文件也没用**：Proton **每次启动**都会重建 prefix 里的字体符号链接
   （实测把 `…/compatdata/<id>/pfx/drive_c/windows/Fonts/msgothic.ttc` 换成自己的，下次启动
   就变回 Proton 的）→ 只能改**源头**，或者用 Proton 不管的文件名。

**修法**

```bash
deck games fonts            # 装（默认 = install）
deck games fonts status     # 看 Proton 源文件 + 每个 prefix 是否就位
deck games fonts rebuild    # 源字体变了/想重新生成 TTC 时用
deck games fonts remove     # 整体还原
```

两层，**第一层才是管用的那层**：

1. **Wine / Proton 层**（`deck/winfonts.sh`）
   - 用一份改名过的中文 TTC 换掉 **Proton 的 `msgothic.ttc`**（原件备份成
     `msgothic.ttc.deckkit-orig`）→ `MS Gothic` / `MS PGothic` / `MS UI Gothic` 全部变成
     全字形的中文。这是唯一活得过"Proton 启动时重建符号链接"的位置。
   - 往每个 prefix 的 `drive_c/windows/Fonts/` 补 `meiryo.ttc`、`msyh.ttc`
     **符号链接**（这两个文件名 Proton 不管，能活下来）→ 补上 `Meiryo` / `Meiryo UI` /
     `Microsoft YaHei UI` 这几个 family，顺带把 Wine 那条断掉的兜底链接上。
   - TTC 由 `mac/mkfont.py` 生成：拿 Proton 自带的 `msyh.ttf`（内部其实是
     **Source Han Sans SC**，glyf 轮廓、44,812 码位），把 name 表改成 7 个 Windows 字体名
     （MS Gothic / MS PGothic / MS UI Gothic / Meiryo / Meiryo UI / Microsoft YaHei /
     Microsoft YaHei UI），做成 TTC —— 大表共享，19 MB。**不用下载任何字体。**
   - 每个 `run.sh` 启动前会后台跑一次 `winfonts.sh ensure --prefix <appid> --quiet`
     （0.4 秒，失败不影响游戏）：Proton 更新/校验把文件换回去之后**下次启动游戏自动复位**；
     新游戏第一次启动才建 prefix，它也会等到 `Fonts` 目录出现再补。
2. **fontconfig 别名**（`deck/fonts.conf` → `~/.config/fontconfig/fonts.conf`）
   对 Proton 游戏没用（见上），留着是因为它对**Linux 原生**程序有效，成本接近零：
   黑体系（`Meiryo UI` `MS Gothic` `SimSun` `微软雅黑`…）→ `Noto Sans CJK SC`，
   衬线系（`MS Mincho` `宋体`…）→ `Noto Serif CJK SC`，外加"任何请求都追加
   Noto Sans CJK SC"的兜底规则。

**几个要点**

- **不碰任何游戏文件**；只动 Proton 的字体文件和 prefix 的 `windows\Fonts` 目录，
  `remove` 可整体还原。卸载游戏不受影响。
- **游戏要重启才生效**（字体在进程启动时枚举）。
- 覆盖前的备份：Proton 原件 `.deckkit-orig`、fontconfig `fonts.conf.deckkit-bak`。
- **Proton 更新后**（Steam 会换掉 `msgothic.ttc`）跑一次 `deck games fonts install`，
  或者直接启动一次游戏让它自愈；`status` 会明确标出哪个 Proton 掉队了。
- 这是**通用修复**：所有"写死 Windows 字体"的汉化游戏都一起吃，不用逐个游戏改。
  副作用只有一个：这些 Windows 字体名现在指向中文（SC）字形，纯日文游戏看到的是
  同字不同形（源氏 vs 简体），不影响阅读。

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
