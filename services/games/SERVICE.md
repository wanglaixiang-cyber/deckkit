# Steam Deck 上的 Windows 游戏：装 → 进 Steam 列表 → 卸载

入口只有一个 `deck games add <你选中的那个文件/目录>`，**是安装包还是免安装游戏，服务自己判断**：

| 你给的 | 判断 | 流程 |
|---|---|---|
| 安装包（`setup.exe`、Inno、NSIS…） | 名字里有 setup/install，**或**文件里有安装器指纹（NSIS/Inno/InstallShield…） | 准备会话（切桌面模式 + 退出 Steam）→ Proton 拉起安装器（你点"下一步"）→ 前后快照对比 → 生成启动脚本 → **自动登记进 Steam** |
| 免安装游戏（整个目录，或游戏文件夹里的 `game.exe`） | 两条都不成立 | 把**它所在的整个目录**拷到 Deck → 在目录里挑主程序（你点的就是 exe 的话直接用它）→ 生成启动脚本 → **自动登记进 Steam**（没有安装器，就不切会话、不开窗口、没什么可等） |

```bash
deck games                            # 概览 + 已装的游戏
deck games add '<setup.exe>'          # 装安装包（向导窗口出现在 Deck 上，你点完成）
deck games add '<游戏目录>'            # 免安装：整份拷过去 + 登记
deck games add '<游戏目录>/game.exe'   # 同上，直接点主程序，不用退到上一层去选目录
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

## 流程（免安装 / 绿色版）

内核完全一样（appid / prefix / `run.sh` / Steam 条目），去掉的正是"装"那一半：

| 环节 | 做法 |
|---|---|
| 拷到 Deck | `tar \| ssh tar -x`（rsync 在 mac/Deck 版本不一致时会翻车）。落 `~/.local/share/deckkit/games/<slug>/game/` —— 和 `run.sh` 同一目录，于是 `deck games rm` 里那条 `rm -rf` 就把游戏本体一起删了，不留残渣 |
| macOS 垃圾 | 两个开关都要：`COPYFILE_DISABLE=1`（不加的话 bsdtar 会给每个带 xattr 的文件附一份 AppleDouble `._名字`，.DS_Store 全排除掉也照样落一地）＋ `--no-xattrs`（不加的话 Deck 的 GNU tar 对每个文件刷一行 `Ignoring unknown extended header keyword`，879M 刷出十几万行） |
| dir slug | 目录名允许中日文（`mygame`），显示名原样进 Steam |
| 主程序 | `gamectl find-game-exe --dir <游戏目录>`：排除 unins/setup/redist/… 后取最大的 exe；你点的就是 exe 的话直接用它 |
| prefix | 照旧先建一个**空的**：第一次启动时 Proton 自己初始化（日志 `Upgrading prefix from None to 11.0-100`） |
| 会话 | 只有"写 `shortcuts.vdf`"这一步需要 Steam 不在跑（和 `shortcut` 共用），拷贝、挑主程序都不需要 |

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

## 已知边界

- **Deck 要在桌面模式**才能看到安装向导 —— 服务会自动切过去，不用你手动切。
- **更新器式安装器**：有的安装器只落 .NET/运行库 + 它自己的 updater（实测 GameSir Connect
  就是这样：595 个新文件里没有主程序）。`finish` 会报"没找到主程序"并停手 —— 这时别登记 Steam 条目。
- **免安装是"整份拷贝"**：拷的是**主程序所在那一层**。数据在上一层（比如 exe 在 `bin/` 里、
  资源在 `bin/..`）时，要么选游戏根目录，要么选根目录那一层的 exe。
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
