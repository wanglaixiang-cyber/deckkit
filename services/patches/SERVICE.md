# 游戏补丁：解包 → 挂载进游戏目录（Steam 校验完整性后一键重挂）

把汉化/素材类补丁（Kagura、Setup Factory、Inno、NSIS 等 exe，或一个补丁文件夹）**解包成文件清单**，
按「游戏目录相对路径」覆盖进 Deck 上的游戏。Deck 上不缓存 exe 和解包结果（按配置），
只留几 KB 的清单；Steam「验证文件完整性」把文件改回去之后状态会自己变回「未挂载」，
**再选一次那个补丁 exe 就能重挂**。

## 能打到哪些游戏

`patchctl games` 会把两边的游戏合成一张表（`appid \t 名字 \t 游戏目录 \t 体积`）：

| 来源 | 游戏目录怎么来的 |
|---|---|
| Steam 游戏 | `steamapps/common/<installdir>`（读 `appmanifest_*.acf`，滤掉 Proton / Steam Linux Runtime） |
| deckkit 免安装游戏 | games 的 `meta.tsv` 里的 `game_dir`（整份拷过去的那个目录） |
| deckkit 安装包版游戏 | games 的 `meta.tsv` 里的 `game_exe` → 它所在那一层（在 prefix 的 `drive_c` 里） |

两边的 id 不会撞号：deckkit 的 appid 是 `crc32|0x80000000`，**永远 ≥ 2^31**，而 Steam 的 appid 都 < 2^31。

```bash
deck patches status                  # 补丁库 + 挂载状态
deck patches games                   # Deck 上能打补丁的游戏（Steam + deckkit 自己装的）
deck patches add '<补丁.exe|文件夹>'   # 解包 → 推断目标游戏（--game 指定）→ 传到 Deck 入库
deck patches mount  <补丁 id>         # 挂载（覆盖游戏文件；不备份）
deck patches unmount <补丁 id>        # 告诉你还原办法（本地没有备份可还原）
deck patches verify  <补丁 id>        # md5 逐文件核对
deck patches menu                    # 给菜单栏用的行（游戏 → 补丁）
deck patches install                 # Deck 侧准备（建库 + 装 patchctl.sh）
```

---

## 为什么不是「让 exe 自己在 Deck 上解压」

补丁 exe 是 Windows 世界的东西，它的安装脚本用 Windows 路径描述目标。实测
`Some Game CN Patch v1.01.exe`（Setup Factory）内部的 Lua：

```lua
reg_test = Registry.GetValue(HKLM, "Software\WOW6432Node\Kagura Games\"..regName, "Install_Path")
install_path("%ProgramFilesFolder%\Steam\steamapps\common\"..gName)
install_path("D:\Steam Library\steamapps\common\"..gName)   … 一直到 Z:、C:\SteamLibrary
```

它**会自己找游戏**（注册表优先，然后按盘符逐个探测并校验），但在 Proton 里：

| 补丁眼里的路径 | 实际指向 |
|---|---|
| `%ProgramFilesFolder%\Steam\steamapps\common\<game>` | prefix 里的 `drive_c/Program Files/...`（**不是**真实游戏目录） |
| `Z:\home\deck\...` | `/home/deck/...`（Proton 把 `Z:` 映射到 `/`） |
| 其它盘符 `D:`…`Y:` | 不存在 |

所以直接跑 exe 的结果是「看着装成功了」，文件却进了 prefix（实测：`/S` 静默跑
一次，游戏目录一个字节都没变）。要让它落到真实目录，得在 prefix 里造
`Program Files/Steam/steamapps/common/<game>` 符号链接指向真实游戏目录（或用
注册表键 `Kagura Games\<name>\Install_Path` 指到 `Z:\...`）—— 也就是「给补丁做引导」。
这条路可行但依赖具体安装器的静默开关和显示环境，而**覆盖绝大多数补丁的做法**是
直接解包成文件（`sfextract` / `innoextract` / `7z`），所以我们默认走解包。
exe 不留（要重挂时在 Mac 上再选一次）——「给补丁做引导」那条路还没做，见下面的已知边界。

## 路径映射（两个世界）

补丁内部的路径要映射成「游戏目录下的相对路径」，这一层单独实现（`patchctl.sh` 的
`cmd_resolve` / `target_of`）：

- payload 根：`%AppFolder%`（Setup Factory）/ `$INSTDIR`（NSIS）/ `app`（Inno）→ 游戏目录本身
- 分隔符：`\` 归一成 `/`（容器里存成 Windows 风格的文件名会被落地成真正的目录）
- 大小写：补丁是 Windows 语义（不敏感），Deck 上敏感 —— 逐段在真实目录里找
  存在的名字（`find -iname`），纠正结果记进 `resolved.tsv`，挂载/卸载都用它

## 为什么要验 md5 而不是信安装器

挂载状态是**算出来的**（比对 md5），不是记出来的：

- 全部文件 = payload 的哈希 → 已挂载
- 全部 = 原始哈希 → 未挂载（Steam 校验完整性之后就回到这里）
- 混合 → 部分挂载 / 状态未知

所以「Steam 校验完整性」这一步不需要通知我们，状态自己会变回未挂载，可以再挂。

## Deck 侧布局

```
~/deckkit/services/patches/
├── patchctl.sh                    Deck 侧执行体（被 deck patches 通过 ssh 调用）
└── store/<appid>/<补丁名>/
    ├── manifest.tsv               <相对路径>\t<md5>\t<字节数>
    ├── resolved.tsv               相对路径 → 实际目标路径（大小写/分隔符纠正）
    ├── meta.tsv                   游戏名 / appid / 原文件名 / 入库时间
    └── mounted_at                 上次挂载时间
```

`patch.exe` 和 `payload/` 只在「入库 → 挂载」这段时间在 Deck 上，挂完立刻删；
`store/<appid>/.game` 是游戏级记录（名字 + 目录），该游戏下最后一个补丁删掉时一起清掉。

## 安全设计

- **不备份被替换的原始文件**（用户明确要求）：Deck 上只留一个几 KB 的
  `manifest.tsv`（路径 + md5），安装包和解包结果都不留。
  要还原就用 Steam 的「验证文件完整性」—— 验证完这里的状态会自动变回
  「未挂载」，之后重新挂载即可（再选一次安装包）。
- **deckkit 自己装的非 Steam 游戏没有「验证文件完整性」**（Steam 不认它的文件）：
  给这类游戏打补丁后要还原，只能回 Mac 重新拷一份
  （`deck games rm <名字>` → `deck games add '<原目录|安装包>'`）。
  `deck patches unmount` 会按游戏目录认出这两种情况，分别给对应的提示。
- 写入用「临时文件 + mv」原子替换，不留半截文件。
- `remove` 非交互环境必须 `--yes`。

## 带安装器的补丁（`add --installer`）

有些补丁解不出「文件包」：自解压壳里面套的是自己的安装脚本，或者它要改注册表、给 exe
打字节补丁 —— 这类只能真把向导跑起来。这条路的入口是显式的一个开关：

```bash
deck patches add '<补丁.exe>' --installer [--game <游戏名|appid>] [--name <短名>]
```

| 环节 | 做法 |
|---|---|
| 目标游戏 | 安装器型**没有文件清单可比对**，只能按**补丁文件名**猜：游戏名整段命中 +6、共享 ≥4 字符的 ASCII 词（Milky/Quest/SOULS…）+1、共享 ≥2 字的中文/日文片段（MyGame3…）+3；只有「最高分 > 0 且严格高过第二名」才采用。猜中会打印出来，不放心就 `--game` 写死 |
| 会话 | **只要桌面模式**（向导要开窗）。补丁不写 `shortcuts.vdf`，所以**不动 Steam** —— 这一点和 games 的安装流程不一样 |
| prefix | 用**游戏自己的** `compatdata/<appid>`：很多补丁的安装脚本先读游戏写下的注册表键才认得出游戏目录；换个 prefix 就会「装完了但游戏目录一个字节都没变」 |
| 拉起向导 | cwd = 游戏目录；`DISPLAY`/`XAUTHORITY` 从桌面会话进程里读；**关掉 Xalia**（`PROTON_USE_XALIA=0`，否则崩溃、窗口永不出现）；输出写 `~/deckkit/services/patches/installer.log`，不继承 ssh 管道。这一步**阻塞**，等到安装器进程退出才返回 |
| 记账 | 安装前后对游戏目录做快照，只看「这次被动过**且**大小/mtime 变了」的文件，逐个算 md5 写进 `manifest.tsv`（格式和文件包型**完全一样**）→ 之后 `status` / `verify` / `list` 全套复用，没有第二套状态机 |
| 收尾 | 按配置删掉 Deck 上的安装器副本（`KEEP_INSTALLER_ON_DECK`）。记录里 `kind=installer`，所以 `mount`/`toggle` 会明确拒绝（库里没有补丁内容，重装要重新上传一次）|

**⚠️ 状态：代码写完、冒烟测试过了，但还没有真实安装器样本。**

冒烟测到的（用一个**不是有效 exe** 的假安装器，正因如此游戏目录一个文件都没变）：
目标游戏按名字猜中（`MyGame2 …`，appid 2689242455）→ 快照到 58 个文件 →
用的是游戏自己的 prefix、cwd 正确、`DISPLAY=:0` / `XAUTHORITY` 解析到、Xalia 关掉、
Proton 11.0 起来、日志落盘 → 0 个文件变化时给出「安装器大概装到别处去了」的提示 →
安装器副本按配置删掉 → 记录 `kind=installer`。diff 那一段另外单独验过：
改内容的记、新增的记、完全没动的不记。

已知边界：

- 安装器把**内容一模一样**的文件又覆盖一遍时，也会被记进 manifest（我们只看得到
  大小/mtime 变了）→ 这种文件在 Steam 校验还原后仍然显示「补丁版本」，整个补丁会
  停在「部分挂载」。这时删除要用 `deck patches remove <补丁> --yes --force`（默认拒绝，
  免得把还原提示删掉）。
- 安装器可能把东西装进 prefix（它以为 `%ProgramFilesFolder%` 就是游戏目录）——
  那样「安装结果」会是 0 个文件，命令会提示你在向导里把路径指到游戏目录
  （Proton 下就是 `Z:` 开头的那条真实路径）。
- 装完没有回滚：不备份（按配置），还原还是 Steam 验证完整性；deckkit 自己装的
  非 Steam 游戏只能回 Mac 重拷。

## 已知边界

- **两类补丁**：能解出文件的「文件包」型（自解压壳 exe、Inno/NSIS/Setup Factory、zip、
  文件夹）走默认那条路；「带安装器的」走 `--installer`（见上一节）。
  解包失败时会把这条命令直接打在报错里，不用回来翻文档。
  `--installer` 这条路**还没有真实样本验收过** —— 第一次用请盯着输出和 `installer.log`。
- 极少数补丁的文件名带 `:` 等 Windows 非法字符，落地时可能需要人工改名。
- 目标推断靠「相对路径能在哪个游戏目录里找到」，命中数为 0 时必须 `--game` 指定。

## 菜单栏

点菜单栏里的 `patches` 一行 → **弹 macOS 文件选择器** → 选一个官方补丁 exe →
自动找 Deck 上已安装的对应游戏 → 挂载（全过程在终端里跑，进度和报错都看得见）。

这一步走的就是一条命令：

```bash
deck patches mount-file '<补丁.exe>'
```

- 库里没有这个 exe 就先入库（按 sha256 认，同一个补丁只会入库一次）；
- 已经挂载着就只做一次 md5 核对，不会重复覆盖；
- **找不到匹配的游戏就报错并列出 Deck 上已安装的游戏**，让你用
  `deck patches add '<补丁.exe>' --game <名字|appid>` 手动指定，绝不乱写。

实现在框架侧是一个通用能力 `pick`（见 `docs/约定.md` §2.1）：
服务的 `caps` 声明 `pick <提示>\t<子命令>`，菜单栏 App 负责弹选择器、
把选中的路径作为参数传给它 —— 这样任何「给我个文件我自己判断」的服务
都能复用，不用往 App 里塞服务专属代码。
