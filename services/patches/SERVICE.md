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
deck patches add '…' --force          # 库里已有同名记录时覆盖它（默认拒绝，见下）
deck patches mount  <补丁 id>         # 挂载（覆盖游戏文件；不备份）
deck patches unmount <补丁 id>        # 告诉你还原办法（本地没有备份可还原）
deck patches verify  <补丁 id>        # md5 逐文件核对
deck patches mount-file '<补丁.exe>'  # 菜单栏那条：分诊 → 找游戏 → 入库 → 挂载
deck patches menu                    # 给菜单栏用的行（转发 Deck 侧 `patchctl.sh menu`）
deck patches install                 # Deck 侧准备（建库 + 推 patchctl.sh、deck-lib、deck-log）
```

**重挂要再选一次安装包**：按配置 Deck 上不留 payload，所以 `mount` / `mount-file`
都会**现场重新解包 + 传一次**（`KEEP_PAYLOAD_ON_DECK=yes` 才直接用库里的缓存）。
唯一例外是「已经挂载着」的补丁：那时只做一次 md5 核对，不重新覆盖。

---

## 为什么不是「让 exe 自己在 Deck 上解压」

补丁 exe 是 Windows 世界的东西，它的安装脚本用 Windows 路径描述目标。实测
`Some Game 2 CN Patch v1.01.exe`（Setup Factory）内部的 Lua：

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
- 写入用「临时文件 + mv」原子替换，不留半截文件：挂载时的目标文件、Deck 上的
  `manifest.tsv`（安装器型那条路先写 `.manifest.XXXXXX` 再 `mv`）、以及 Mac → Deck
  的上传（`rsh_put` 先写 `<路径>.deckkit-tmp` 再 `mv`）都是这个写法。
- `remove` 非交互环境必须 `--yes`。

## 带安装器的补丁（`add --installer`）

有些补丁解不出「文件包」：自解压壳里面套的是自己的安装脚本，或者它要改注册表、给 exe
打字节补丁 —— 这类只能真把向导跑起来。

**两条入口，效果一样：**

```bash
# ① 显式开关（终端）
deck patches add '<补丁.exe>' --installer [--game <游戏名|appid>] [--name <短名>]

# ② 从菜单栏/选择器点（不用记开关）—— 会自己认出是安装器型并转过来
deck patches mount-file '<补丁.exe>'
```

② 靠 `patch-extract.py classify` 先分诊（见下面的「怎么认出安装器型」），
是安装器型就自动转 ①，并按补丁文件名**自动推断目标游戏**；只有推断不出时才
让你手输一次 `--game`（会把 Deck 上的游戏列表打出来）。
以前 ② 对安装器型是**直接失败的**（走解包 → 解不开 → 报错），看起来就是「选了没反应」。

| 环节 | 做法 |
|---|---|
| 目标游戏 | 安装器型**没有文件清单可比对**，只能按**补丁文件名**猜：游戏名整段命中 +6、共享 ≥4 字符的 ASCII 词（Milky/Quest/SOULS…）+1、共享 ≥2 字的中文/日文片段（MyGame3…）+3；只有「最高分 > 0 且严格高过第二名」才采用。猜中会打印出来，不放心就 `--game` 写死 |
| 会话 | **只要桌面模式**（向导要开窗）。补丁不写 `shortcuts.vdf`，所以**不动 Steam** —— 这一点和 games 的安装流程不一样 |
| prefix | 用**游戏自己的** `compatdata/<appid>`：很多补丁的安装脚本先读游戏写下的注册表键才认得出游戏目录；换个 prefix 就会「装完了但游戏目录一个字节都没变」。用的是**游戏自己的** prefix，所以补丁眼里这台"电脑"就是装过该游戏的那台 |
| 拉起向导 | cwd = 游戏目录；`DISPLAY`/`XAUTHORITY` 从桌面会话进程里读；**关掉 Xalia**（`PROTON_USE_XALIA=0`，否则崩溃、窗口永不出现）；输出写**统一日志**（`~/deckkit/logs/patches-installer.log`，读：`deck logs patches-installer`；`deck-log` 不在才退回 `~/deckkit/services/patches/installer.log`），不继承 ssh 管道。这一步**阻塞**，等到安装器进程退出才返回 |
| 记账 | 安装前后对游戏目录做快照，**整目录对比**：快照里没有的（新增）或大小/mtime 变了的 → 记；完全一致的 → 不记。逐个算 md5 写进 `manifest.tsv`（格式和文件包型**完全一样**）→ 之后 `status` / `verify` / `list` 全套复用，没有第二套状态机 |
| 重装 | 记录里 `kind=installer`，库里**没有**补丁内容，所以 `mount`/`toggle` 会被拒绝。重装要**再选一次那个 exe**（走 ① 或 ② 都行，②会认出来并重新跑向导）|
| 收尾 | 按配置删掉 Deck 上的安装器副本（`KEEP_INSTALLER_ON_DECK`）|

### 怎么认出「安装器型」（`patch-extract.py classify`）

解包失败时**不再笼统说「它可能是真安装器」** —— 实测有私有加密壳会被这么说，
用户按提示重试还是失败，不知道到底该干嘛。现在解包前/失败后都当场分类，
把**判定依据**打出来：

| 判定 | 依据 | 走法 |
|---|---|---|
| `installer` | 文件里找到 Inno / NSIS / InstallShield / Setup Factory / Wise 指纹 | 安装器流程 |
| `selfextract` | 代码段很小（< 4MB）但尾部附加 > 8MB **且熵 > 7.9**（加密/压缩）→ 私有自解压器，解包器都不认 | 安装器流程 |
| `sfx_plain` | 有附加数据但熵不高，像普通自解压 | 先试解包；解不开再安装器 |
| `plain` | 没有明显附加数据 | 解包（多半本来就能解） |
| `not_pe` | 不是 PE（zip/7z/文件夹） | 直接解包 |

实测：`Some Game 3 Full ver patch CH.exe`（479MB，代码段仅 0.2MB、
尾部 479.3MB 高熵）被判 `selfextract` → 转安装器流程；
`Another Game CN patch.exe` 等能解的被判 `plain` → 照旧走解包，**没有回归**。

**⚠️ 状态：代码写完、冒烟测试过了；真实安装器样本（Some Game 3 官方汉化补丁）
已能正确分诊并转进这条路，但「向导真正把文件装进游戏目录」还待实测验收。**

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
- **别指望安装器会自己找到游戏目录。** 实测 `Some Game 3 Full ver patch CH.exe`
  （私有自解压器、VC++ 写的）代码段里**只有通用 Win32 串**，既没有 `OTAKU_Plan` /
  `bikini` 这类游戏专属键名，也只读 `Software\Microsoft\Windows\CurrentVersion`
  拿 `ProgramFilesDir`。也就是说：**它不读游戏注册的 `install_path`**，
  游戏自己的 prefix 帮不上忙 —— 向导里的安装目录默认是**空白**的，
  必须人工填。这条是 2026-10 实测得出的，和早先「补丁会认注册表键」的假设相反：
  **能不能自动认出游戏，取决于具体补丁**，不要预设。
  所以向导起来后，请直接把「安装结果」里给的那条绝对路径填进去。
- 装完没有回滚：不备份（按配置），还原还是 Steam 验证完整性；deckkit 自己装的
  非 Steam 游戏只能回 Mac 重拷。
- **不能用 mtime 找"刚装进去的文件"**（踩过，已修）：很多安装器/自解压器把文件
  时间戳设成**打包时的时间**（作者那边），于是新写入的文件 mtime 反而比"安装开始
  时刻"更早 → `find -newermt @since` 一个都匹配不到。实测 Some Game 3
  官方汉化补丁：装进去 1467 个文件，时间戳全是补丁打包时的 `01:12~01:14`，
  而安装动作发生在 `03:03` → 旧写法只命中 2 个（游戏自己写的 `debug.log` /
  存档），manifest 记成 **0 条**，`status` 显示「0 个文件 · 状态未知」，
  看起来像"没装上"，其实装得好好的（游戏目录 965M → 1.4G、+1467 文件）。
  现在改成**和安装前快照整目录对比**，与 mtime 无关。

## 实现备注（评审后修的几处，供下次读代码时对表）

这些是 2026-10 的只读评审抓到的健壮性问题，改完的现状记在这里 —— 免得下次又被
"看着可以简化"改回去：

| 约定 | 为什么 |
|---|---|
| `patchctl.sh list` 在库不存在时**不输出任何东西** | 这一行是给 Mac 侧解析的（`<id>\t<游戏>\t…`）。以前打一行 `(补丁库是空的)`，Mac 那边 `grep -c .` 会把它数成「1 个补丁」 |
| `patchctl.sh find-sha` **没找到 = 输出空 + 退出码 0** | 退出码只回答"命令跑通了没"。以前没找到返回 1，和 ssh 失败同码 → Mac 侧一个 `\|\| true` 就分不清「库里没有」和「连不上」，白走一遍重复入库 |
| `patchctl.sh snapshot` 用公共库的 `deckkit_snapshot` | 旧写法 `find \| sort` 的退出码来自 `sort`（恒 0），`\|\| die "快照失败"` 永不触发 → 空快照被当成「安装前后一个文件都没变」，把**执行失败报成安装失败** |
| `manifest-from-install` 先写临时文件再 `mv` | 以前 `: > manifest.tsv` 再追加：中途失败会把旧清单截空，state 显示「状态未知」，看起来像没装上 |
| `add` 遇到库里已有同 id 记录 → **默认拒绝**（`--force` 才覆盖） | 同名不同来源的补丁以前直接覆盖写，前一份的 `manifest.tsv` / `meta.tsv` **静默丢掉** |
| `remove` 只接受 `store/<appid>/<补丁>` 这一层 | 以前只校验"目录存在"：`patchctl.sh remove <store 根>` 会把整个补丁库删掉 |
| `mount` 的目标已经是**目录**时跳过并报警 | `mv -f tmp target` 在 target 是目录时会把 tmp **搬进那个目录**，等于挂了个空气 |
| 状态/校验用"预读"版（`cmd_state` / `cmd_verify`） | 逐文件走 `file_state → target_of → game_dir_of` 全是 `$(...)` 子 shell；现在先把 gdir、hash 策略、`resolved.tsv` 映射读进变量，循环里只剩 md5sum/stat。实测同一个补丁（1467 个文件）的 `verify`：**47.5s → 3.5s**（结论一致）。**别把这两个函数改回逐文件调用** |
| 再到「**一次进程内批量**」：`state_scan` | 上面那版虽然只剩 `md5sum`/`stat`，但仍是**每个文件 fork 一次**。实测一个 1467 文件的补丁：`stat` 1611 次 + `md5sum` 137 次 = 约 1748 次 fork、**6.4 秒 CPU**（sys 3.8s 全是 fork/exec 的开销，磁盘读其实是 0 —— 全在页缓存里）。而菜单栏每 30 秒就要问一次状态，等于让 Deck 一直烧 0.43 核。现在整批交 `state_scan`：一个 `python3` 进程里把 1748 个文件的 stat/md5 全做完，fork 降到 **6 次/轮**，同一个补丁 **6.4s → 2.2s**（剩下的 2 秒是 md5 真读 1 GB 文件的固有代价，约 420 MB/s，不是开销）。**三条纪律**：① `state_scan` 全程走 **bytes**（Deck 的 locale 是 POSIX，路径里还有中日文，走 str 会踩编码）；② 它只往 stdout 输出 ASCII 状态词，**路径不经过 stdout**（不给自己制造编码往返的机会）；③ 快路（python3）与慢路（纯 bash 兜底）**必须逐字节一致** —— 改完在 5 个补丁 × 2 种 hash 模式上对比过 |
| 面板与计数**只算一遍**（`patch_state_rows` + `status --tsv`） | Mac 侧原来先 `pctl list` 取计数、再 `pctl status` 画面板 —— 两趟各自把同一份 md5/stat 在 Deck 上重算一遍（一轮白烧 ~6 秒）。现在 Deck 侧算一次状态，面板之后附一段 `@@TSV` 给 Mac 侧计数用（不带 `--tsv` 时输出和以前一模一样）。**`deck patches status`：12.1s → 2.45s** |
| `cmd_games` 的体积读 `appmanifest_*.acf` 的 `SizeOnDisk` | 它被 `list`/`status`/`menu`/`suggest` 反复调用（菜单栏每 30 秒一轮）；每个游戏递归 `du -sh` 会让那一轮全卡在遍历几十上百 GB 上。读不到才退回 du |
| 兼容层过滤只有一处规则（`is_runtime`，两个文件里逐字相同） | 以前 Mac 侧写 `*Steamworks*`、Deck 侧写两条全称 —— 同一条规则分叉了。改一处必须改另一处 |
| Mac 侧脚本里的远端路径一律 `$DECK_PATCH_ABS` + `printf %q` / `rsh_script` | `config.env` 的 `DECK_PATCH_ROOT` 以前被硬编码 `~/deckkit/services/patches` 架空；`$id`/`$name` 直接拼进远端命令串等于把执行权交给输入 |
| `mac/patch-extract.py` 对**用户给的目录只读** | 需要把 Windows 反斜杠路径落地成目录时，先硬链到 work 里再改名；扫到 macOS 的 `._*` 陪衬文件只跳过、不再 `os.remove` |
| 公共库 `~/deckkit/bin/deck-lib` 由 `deck patches install` 一起推 | Deck 侧 `patchctl.sh` 开头 source 它（快照/Proton 枚举/桌面会话/消息函数）。库缺失时走脚本里的兜底分支，服务仍能跑；兜底只放 patchctl 用到的那几个函数 |

## 已知边界

- **两类补丁**：能解出文件的「文件包」型（自解压壳 exe、Inno/NSIS/Setup Factory、zip、
  文件夹）走默认那条路；「带安装器的」走 `--installer`（见上一节）。
  解包失败时会把这条命令直接打在报错里，不用回来翻文档。
  `--installer` 这条路**还没有真实样本验收过** —— 第一次用请盯着输出和 `installer.log`。
- 极少数补丁的文件名带 `:` 等 Windows 非法字符，落地时可能需要人工改名。
- 目标推断靠「相对路径能在哪个游戏目录里找到」，命中数为 0 时必须 `--game` 指定。
  入库时会多打一行「路径证据：命中 N/M，其中该游戏原有文件 K 个」——
  `K` 很小说明这个补丁在该游戏里几乎全是新增文件、路径证据偏弱，会额外提醒一句。
  **没有用 md5 内容比对当判据**：补丁一旦挂载，文件内容就等于 manifest，而且
  坏挂载会污染内容（实测二代被一代补丁覆盖后，二代**自己的**补丁都比对不上），
  内容比对既分不出"打对了已挂载"和"打错了被覆盖"，还会给出反向结论。
- **同名系列作必须用 `--game` 指定**（实测踩过：`Another Game` 一代补丁被挂到
  `Another Game 2` 上）。两代同引擎、同顶层目录结构，前作补丁的路径在续作目录里
  **63/63 全部命中**，而前作自己只命中 2 个 —— "命中最多者胜"必然倒向续作。
  更麻烦的是**这种误判看起来极其可信**：赢家 100%、输家 3%，比分悬殊到任何
  "比例/并列"检查都不会报警。所以只要候选里出现名字互为前缀的一对
  （`Another Game` ⊂ `Another Game 2`）且两边都有命中，服务就**拒绝自动选**，
  直接把两个候选和各自命中数打出来，要求你 `--game` 指定。
  实测两个方向都会被拦（一代补丁 2 vs 63、二代补丁 3 vs 144），
  而 `--game` 一旦给了就不再追问。非系列作不受影响（Some Game 2 照常自动选中）。

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
