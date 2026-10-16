// ============================================================
//  deckkit —— 框架级菜单栏 App
//
//  图标用 Steam Deck 官方 logo 的「机身标记」（不含 STEAM DECK 字样），
//  以 template image 渲染：自动适配浅色/深色菜单栏，Deck 离线时压暗。
//
//  菜单内容：
//    · Steam Deck 状态（在线/离线 + 主机名 + 上次刷新时间）
//    · 各服务的一行状态（来自 services/<名字>/service status 的第一行）
//    · 刷新 / 游戏管理（终端交互列表）/ 完整状态 / 打开 deckkit 目录 / 退出
//
//  约定（docs/约定.md §5）：绝不在主线程做同步网络调用 —— 所有探测都在
//  后台队列上跑，并带超时；结果回到主线程再重建菜单。
// ============================================================
import Cocoa
import UniformTypeIdentifiers        // 选择器的文件类型过滤用 UTType（macOS 11+）

// ─────────────────────────── 路径与配置 ───────────────────────────
// 框架根目录按三步找：
//   ① 环境变量 DECKKIT_ROOT（测试用）
//   ② Info.plist 的 DeckkitRoot —— **装到 /Applications 之后靠它**：
//      那时 Bundle 在 /Applications/DeckKit.app，往上两级是 /，找不到 services/
//   ③ 兜底：Bundle 在 <deckkit>/menubar/DeckKit.app，往上两级就是框架根目录
let deckkitRoot: String = {
    let fm = FileManager.default
    if let r = ProcessInfo.processInfo.environment["DECKKIT_ROOT"], !r.isEmpty,
       fm.fileExists(atPath: r + "/services") {
        return r
    }
    if let r = Bundle.main.object(forInfoDictionaryKey: "DeckkitRoot") as? String, !r.isEmpty,
       fm.fileExists(atPath: r + "/services") {
        return r
    }
    // NSString.deletingLastPathComponent 返回 String，要再桥回去才能继续剥。
    let menubar = (Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString
    return menubar.deletingLastPathComponent
}()
let servicesDir = deckkitRoot + "/services"
let deckCLI = deckkitRoot + "/bin/deck"

/// 框架根没找到时的一句人话（nil = 找到了）。
///
/// 以前这里没有兜底：三步都失败时 deckkitRoot 退化成 Bundle 的上两级（装到
/// /Applications 时就是 "/"），servicesDir 变成 "//services" —— 菜单里只剩
/// 「（services/ 下没有可用服务）」，用户完全看不出是**仓库挪了**。
/// 找到根目录这件事必须自己说出来，不能静默退化。
let deckkitRootProblem: String? = {
    if FileManager.default.fileExists(atPath: servicesDir) { return nil }
    return "找不到框架根目录：\(servicesDir) 不存在（试过 DECKKIT_ROOT、"
         + "Info.plist 的 DeckkitRoot、App 的上级目录）—— 仓库挪过就重新 deck menu --install"
}()

// SSH 别名由 bin/deck 自己从 DECKKIT_DECK_SSH / 默认值决定，这里只管显示用的主机名。
let deckHost = ProcessInfo.processInfo.environment["DECKKIT_DECK_HOST"] ?? "steamdeck.local"

let ICON_HEIGHT: CGFloat = 16
/// 刷新间隔。每轮要开 6~8 个 SSH 连接，靠 ControlMaster 复用后一轮约 0.3 秒
///（复用前约 2.6 秒），所以 30 秒一次很便宜。
let REFRESH_SECONDS: TimeInterval = 30
let STATUS_TIMEOUT: TimeInterval = 20
/// 连续失败几轮才把图标翻成「离线」。
/// 刷新间隔 30 秒，所以 2 轮 ≈ 1 分钟 —— 真断网/关机一分钟内必然翻红，
/// 而一次瞬时抖动（ssh 那 5 秒 ConnectTimeout 偶发踩线）只会被记进日志、不动图标。
let DEBOUNCE_ROUNDS = 2

// ─────────────────────────── 子进程执行 ───────────────────────────
struct RunResult { let code: Int32; let out: String }

/// 子进程的三种收场。以前用裸的 -1 / -2 混在 `code` 里，读代码时得靠注释回忆。
enum RunOutcome {
    static let launchFailed: Int32 = -1     // 没跑起来（ENOENT / EACCES…）
    static let timedOut: Int32 = -2         // 我们把它掐了（≠ 命令失败，≠ 离线）
}

func run(_ exec: String, _ args: [String], timeout: TimeInterval = STATUS_TIMEOUT,
         extraEnv: [String: String] = [:]) -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exec)
    p.arguments = args
    // 图形界面启动的进程 PATH 很窄，不含 brew 的目录（约定 §5）。
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    for (k, v) in extraEnv { env[k] = v }
    p.environment = env

    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe

    // 起不来就把原因原样带出去（约定 §7：失败必须带原始原因）。
    // 以前这里返回 (code:-1, out:"")，日志里只剩「rc=-1 输出=(空)」—— 和
    // 「跑起来了但没输出」长得一模一样，等于把 ENOENT/EACCES 扔了。
    do { try p.run() } catch { return RunResult(code: RunOutcome.launchFailed, out: "启动失败：\(error)") }

    // 父进程放开写端。不放的话 EOF 永远不会到：子进程拿一份写端，它起的
    // 常驻后代（`next dev` 那种）也拿一份，管道就一直是「还有人可能写」。
    pipe.fileHandleForWriting.closeFile()

    // 读端用**独立 dup 出来的** fd。原来这里是 `let fd = pipe.fileHandleForReading
    // .fileDescriptor` + `defer { close(fd) }` —— 那个 fd 归 FileHandle 所有，
    // 我们手动关掉它、等 pipe 析构时 FileHandle 又关**同一个号**，而那时这个号
    // 早被另一个并发调用新开的管道复用了。
    //
    // 对照实验（/tmp/fdtest）：320 次并发调用里 32 次「读端被误关」、32 次
    // 「输出为空而 rc 仍是 0」；换成 dup 后是 0 / 0。而生产环境里的长相正是
    // 「Deck 明明在线，菜单栏却显示离线」—— 日志里那几行 `rc=0 耗时=0.20s
    // 输出=(空)` 就是这么来的：read 拿到 EBADF → 直接收工 → 什么都没有。
    let readFd = dup(pipe.fileHandleForReading.fileDescriptor)
    guard readFd >= 0 else { return RunResult(code: RunOutcome.launchFailed, out: "无法复制管道 fd") }
    defer { close(readFd) }
    let flags = fcntl(readFd, F_GETFL)
    if flags != -1 { _ = fcntl(readFd, F_SETFL, flags | O_NONBLOCK) }

    // 边跑边读，**不能先等退出再读**：子进程往一个没人读的管道里写超过管道容量
    // （macOS 64KB）就会阻塞在 write 上、永远不退出 —— 我们只能等满超时、把它
    // SIGTERM 掉、再报一个假的「检测中」。实测 65KB 的输出就是这个下场，
    // 而 ≤64KB 一切正常，所以这个 bug 只在某几个服务上露面。
    let lock = NSLock()
    var buf = Data()
    let readerDone = DispatchSemaphore(value: 0)
    // 读线程用**独立 Thread**，不占 libdispatch 的线程池：一次刷新最多 8 个
    // 并发调用，池子被这类长命块占住之后，下面等退出的那个块有可能迟到 ——
    // 实测会出现「/bin/echo 也等满 10 秒超时」的假超时（5/320）。
    // 池子只负责「短任务」，长命等待都用独立线程/回调。
    let reader = Thread {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(readFd, &chunk, chunk.count)
            if n > 0 {
                lock.lock(); buf.append(contentsOf: chunk[0..<n]); lock.unlock()
            } else if n == 0 {
                break                                    // EOF：写端全关了
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(5_000)                            // 暂时没数据，歇一下再看
            } else if errno == EINTR {
                continue
            } else {
                break                                    // 其它错误：收工
            }
        }
        readerDone.signal()
    }
    reader.start()

    // 等退出也**不用「阻塞线程 + 信号量」**：terminationHandler 是子进程退出时
    // 由 Foundation 调的回调，既不占我们的线程，也不会有「等待块排不上队 →
    // 明明 0.01 秒就退出的命令却等满超时」这种假超时。
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }

    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        // 先用 SIGTERM 讲道理；服务脚本可能是 `exec` 出来的常驻进程（要起
        // `npm run dev` 这类后代），SIGTERM 未必立刻生效，所以补一记 SIGKILL，
        // 免得 waitUntilExit 又变成新的永久挂点。
        p.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
    }
    // 收尾：子进程已经退出 ⇒ 写端关得差不多了 ⇒ EOF 很快到；真有常驻后代
    // 攥着写端不放也不能再等（这正是旧实现永久挂住的地方）。
    _ = readerDone.wait(timeout: .now() + 1.0)
    lock.lock(); let data = buf; lock.unlock()

    // 超时仍旧返回空输出（保持「超时 = 问不出来」的既有语义：菜单栏据此
    // 显示「检测中…」而不是拿半截输出去解析出一个可能是假的结论）。
    if timedOut { return RunResult(code: RunOutcome.timedOut, out: "") }
    return RunResult(code: p.terminationStatus, out: String(data: data, encoding: .utf8) ?? "")
}

// ─────────────────────────── 日志 ───────────────────────────
/// 菜单栏的「黑匣子」。以前 App 是**完全静默**的：离线只在图标上闪一下，
/// 不留任何痕迹，事后只能靠人回忆「刚才好像红了一下」—— 没法定位。
///
/// 现在按统一日志约定记（见 docs/约定.md 的「日志」一节）：
/// 位置、格式、保留上限都和 bin/deck-log 一致，读的时候一个 `deck logs menubar` 就行。
/// 只记**状态变化**那一行（在线→离线、离线→在线、检测中…），外加服务行变化，
/// 不是每轮都刷 —— 否则「一切正常」会把真事淹掉。
///
/// 关键是把「为什么判成离线」的原料一起写下来：退出码、耗时、原始输出
///（含 deck 脚本带出来的 ssh 失败原因 why）。
/// 这才能区分下面这两种以前长得一模一样的失败：
///   · ssh 自己失败   → deck 脚本返回 rc=0 且打印 {"online":false}
///   · App 把进程掐了 → RunOutcome.timedOut（这才是代码里 `unknown` 认的那种「超时」）
enum Log {
    /// 日志位置。**必须**和 bin/deck-log 的 log_dir() 算出同一个目录 ——
    /// 那是「统一」的全部意义：`deck logs --list` 要能一眼看全所有来源，
    /// 写到了别处就等于又多了一套散在外面的日志。
    static let path: String = {
        if let d = ProcessInfo.processInfo.environment["DECKKIT_LOG_DIR"], !d.isEmpty {
            return (d as NSString).appendingPathComponent("menubar.log")
        }
        return NSString(string: "~/Library/Logs/deckkit/menubar.log").expandingTildeInPath
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let q = DispatchQueue(label: "deckkit.menubar.log")

    /// 台账只留最近这么多**条事件**（和 bin/deck-log 的 DECKKIT_LOG_MAX_LINES
    /// 默认值保持一致 —— 上限不统一的话，「每个来源保留多久」就又变成两套说法了）。
    ///
    /// 日志是**事件驱动**的（不是每轮心跳）：正常在线时一轮不写一行，
    /// 所以 100 条覆盖的是「最近 100 次值得记的事」，而不是 100×30 秒=50 分钟。
    /// 记三类：主机状态真的变了、「探测失败但还在观察期」的抖动、
    /// 服务行变化 —— 抖动那条正是「时不时显示离线、其实主机在线」的原始证据。
    /// 上限读**和 bin/deck-log 同名**的环境变量。注释说两边「刻意保持一致」，
    /// 那就得真的能一致：硬编 100 的话，用户给 deck-log 设了变量，
    /// 「统一日志」立刻变成两套上限，而文件里只有最近 100 条这件事没人看得出来。
    static let maxLines: Int = {
        if let v = ProcessInfo.processInfo.environment["DECKKIT_LOG_MAX_LINES"],
           let n = Int(v), n > 0 { return n }
        return 100
    }()

    /// 单条消息的字符上限：同一个变量名、同一个默认值（800），对齐 deck-log。
    static let maxChars: Int = {
        if let v = ProcessInfo.processInfo.environment["DECKKIT_LOG_MAX_CHARS"],
           let n = Int(v), n > 0 { return n }
        return 800
    }()

    static func line(_ msg: String, sync: Bool = false) {
        // --dump 是「命令行自检」：只为看一眼当下菜单长什么样，
        // 不该往真实日志里塞它的启动/状态行（否则 grep 出来的时间线全是噪音）。
        if CommandLine.arguments.contains("--dump") { return }
        let text = "\(fmt.string(from: Date()))  \(msg)"
        // sync：退出锚点这类「写完进程就没了」的场合用 —— 异步投递会丢。
        let write = {
            let fm = FileManager.default
            let dir = (path as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            // 追加一条 → 超过上限就从头部丢最旧的 → 原子写回整份。
            // 写入是事件驱动的（一小时可能就一两行），「读+写整份」的开销可以忽略，
            // 换来的是文件里永远只有最近 maxLines 条、不用维护任何索引。
            var lines: [String] = []
            if let d = fm.contents(atPath: path), let s = String(data: d, encoding: .utf8) {
                lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if lines.last == "" { lines.removeLast() }   // 去掉末尾换行留下的空元素
            }
            lines.append(text)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            try? (lines.joined(separator: "\n") + "\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        if sync { q.sync(execute: write) } else { q.async(execute: write) }
    }

    /// 日志里不能出现换行/tab（一行一条，方便 grep），也不能太长。
    static func oneline(_ s: String, limit: Int? = nil) -> String {
        let cap = limit ?? maxChars
        var t = s.replacingOccurrences(of: "\n", with: "⏎")
                   .replacingOccurrences(of: "\r", with: "")
                   .replacingOccurrences(of: "\t", with: " ")
        if t.count > cap { t = String(t.prefix(cap)) + "…（截断）" }
        return t
    }
}

// ─────────────────────────── 文本工具 ───────────────────────────
func stripANSI(_ s: String) -> String {
    // 字符类里必须有 `?`：工具收尾时会打印 ESC[?25h（恢复光标）这类带问号的
    // 序列，只写 [0-9;] 匹配不到，菜单里就会残留控制字符 —— bin/deck-log 的
    // --list 踩过同一个坑，两边保持一致。
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
}

/// 取第一行非空内容 —— 与 bin/deck 概览的取法一致（约定 §2）。
func firstLine(_ s: String) -> String {
    for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = stripANSI(String(raw)).trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { return line }
    }
    return ""
}

/// 把**计数型**的数字抹成 N 再比对（服务行变化检测用，见 logServiceChanges）。
///
/// 服务摘要里混着两种数字，必须区别对待：
///   · 计数型 —— 那一行「77,813 条索引 · 60 个节点」每轮都在涨，
///     不抹平的话「服务状态变化」就退化成每轮一行的心跳，把真事淹掉
///   · 状态型 —— patches「已挂载 4 · 未挂载 0 · 异常 1」、games「14 个」这种
///     短数字，还有 IP / 端口 / 版本号 / 温度，它们变了正是要记的事
///
/// 判据是「数字 + 量词」，不是「数字有几位」（旧写法只看位数，实测漏掉两类：
/// 节点数那种两位数每轮都跳却照记；而 `:8080`／`192.0.2.10`／`已用 102 GB`
/// 这种该保留的反被抹成 `:N`／`N.N.1.N`／`已用 N GB`）。分两档：
///
///   · 任何位数：紧跟「条 / 节点 / 个 DHT 节点」—— 这几个字段是**每轮都在变**的
///     计数（索引条数、DHT 节点数），位数不固定，只按位数判会漏
///   · 3 位以上：紧跟其它量词（个 / 项 / 次 / 行 / 文件）—— 那些多是状态量，
///     只有大位数才是累计值
func normDigits(_ s: String) -> String {
    // ICU 正则支持前瞻：只匹配「数字」，「后面紧跟量词」只作条件、不被消费。
    // 量词进前瞻（`(?=…)`），也就是**只替换数字、不动量词** —— 这样归一化后的
    // 文本读起来还是「N 条索引 · N 个 DHT 节点」，而不是「N索引 · N」。
    let churn = "[0-9][0-9,]*(?=[[:space:]]*(?:条|节点|个[[:space:]]*DHT[[:space:]]*节点))"
    let counted = "[0-9][0-9,]{2,}(?=[[:space:]]*(?:个|项|次|行|文件))"
    return s.replacingOccurrences(of: churn, with: "N", options: .regularExpression)
            .replacingOccurrences(of: counted, with: "N", options: .regularExpression)
}

func truncate(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(max(n - 1, 1))) + "…"
}

// ─────────────────────── Steam Deck 官方 logo ───────────────────────
// 取自官方 logo 的机身标记部分（viewBox 里 x∈[0,37.04]、y∈[0,49.39]），
// 右边的「STEAM DECK」字样不要 —— 菜单栏只需要那个标记。
func logoImage(height: CGFloat, dimmed: Bool) -> NSImage {
    let markW: CGFloat = 37.0385
    let markH: CGFloat = 49.3856
    let size = NSSize(width: max((height * markW / markH).rounded(), 1), height: height)

    let img = NSImage(size: size)
    img.lockFocus()
    if let ctx = NSGraphicsContext.current?.cgContext {
        // SVG 的 y 轴朝下，AppKit 的朝上 —— 翻一下再按原始坐标画。
        let s = height / markH
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: s, y: -s)

        let path = CGMutablePath()
        // 机身的「D」形环（官方路径原样转写）
        path.move(to: CGPoint(x: 28.1744, y: 24.6928))
        path.addCurve(to: CGPoint(x: 12.3457, y: 8.86409),
                      control1: CGPoint(x: 28.1744, y: 15.9508),
                      control2: CGPoint(x: 21.0877, y: 8.86409))
        path.addLine(to: CGPoint(x: 12.3457, y: 0))
        path.addCurve(to: CGPoint(x: 37.0385, y: 24.6928),
                      control1: CGPoint(x: 25.9832, y: 0),
                      control2: CGPoint(x: 37.0385, y: 11.0553))
        path.addCurve(to: CGPoint(x: 12.3457, y: 49.3856),
                      control1: CGPoint(x: 37.0385, y: 38.3303),
                      control2: CGPoint(x: 25.9832, y: 49.3856))
        path.addLine(to: CGPoint(x: 12.3457, y: 40.5215))
        path.addCurve(to: CGPoint(x: 28.1744, y: 24.6928),
                      control1: CGPoint(x: 21.0877, y: 40.5215),
                      control2: CGPoint(x: 28.1744, y: 33.4348))
        path.closeSubpath()
        // 左侧的圆
        let r: CGFloat = 12.3464
        path.addEllipse(in: CGRect(x: 12.3464 - r, y: 24.7191 - r, width: r * 2, height: r * 2))

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setAlpha(dimmed ? 0.35 : 1.0)
        ctx.addPath(path)
        ctx.fillPath()
    }
    img.unlockFocus()
    // template：系统按 alpha 着色，浅色/深色菜单栏和高亮态都自动正确。
    img.isTemplate = true
    return img
}

// ─────────────────────────── 状态 ───────────────────────────
struct SvcLine {
    let name: String
    let line: String
    /// 该服务声明了 toggle 能力吗（点一下就切换主状态，而不是只看详情）。
    var canToggle: Bool = false
    /// 点击提示，取自 caps 里 toggle 后面那句说明。
    var toggleHint: String = "切换状态"
    /// caps 里声明了 `pick`：点这个服务先弹文件选择器，
    /// 选中的文件作为参数传给 pickCmd（约定 §2.1）。
    /// 第三列（可选）是文件类型过滤，`*` = 不限（比如 games 既要 .exe 又要整个目录）。
    var pickCmd: String = ""
    var pickHint: String = "选择文件"
    var pickTypes: [String] = []
}

/// Deck 遥测，全部来自 `deck vitals --json`（读 Deck 的 sysfs）。
struct Vitals {
    var capacity: Int? = nil
    var status: String = ""
    var ac: Bool? = nil
    var apuC: Double? = nil
    var batC: Double? = nil
    var uptimeS: Int? = nil
    var load1: Double? = nil

    static func parse(_ out: String) -> Vitals? {
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["online"] as? Bool) == true
        else { return nil }

        var v = Vitals()
        // 脚本用 -1 / null 表示读不到，这里都归成 nil。
        func num(_ k: String) -> Double? {
            if let d = obj[k] as? Double, d >= 0 { return d }
            if let i = obj[k] as? Int, i >= 0 { return Double(i) }
            return nil
        }
        if let c = num("capacity") { v.capacity = Int(c) }
        v.status = (obj["status"] as? String) ?? ""
        if let a = num("ac") { v.ac = (a > 0) }
        v.apuC = num("apu_c")
        v.batC = num("bat_c")
        if let u = num("uptime_s") { v.uptimeS = Int(u) }
        v.load1 = num("load1")
        return v
    }

    /// 「充电中 / 已接电源（未充电）/ 使用电池」——Deck 有电池保养，
    /// 插着电也可能停在 ~80% 并报 Not charging，所以这两种要分开说。
    var chargeText: String {
        switch (ac, status) {
        case (true, "Charging"):      return "充电中"
        case (true, "Full"):          return "已充满"
        case (true, "Not charging"):  return "已接电源（未充电）"
        case (true, _):               return "已接电源"
        case (false, "Discharging"):  return "使用电池"
        case (false, _):              return "使用电池"
        case (nil, _):                return ""
        }
    }

    /// 插着电 = 正常；在用电池 = 对一台常驻服务器是要留意的事。
    /// `ac` 读不到（-1）但有明确的放电状态时也算在用电池 —— 否则最该标黄的那次
    /// （读不到电源状态、又能确定在放电）反而不标。
    var onBattery: Bool { ac == false || (ac == nil && status == "Discharging") }

    var durationText: String? {
        guard let s = uptimeS, s > 0 else { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)分钟" }
        return "不到 1 分钟"
    }
}

func serviceNames() -> [String] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: servicesDir) else { return [] }
    return items.filter { name in
        var isDir: ObjCBool = false
        let dir = servicesDir + "/" + name
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.isExecutableFile(atPath: dir + "/service")
    }.sorted()
}

/// caps 的解析结果（约定 §2.1：`<子命令> [一句说明]`，pick 那行是 tab 分隔的三列）。
struct Caps {
    var canToggle = false
    var toggleHint = "切换状态"
    var pickCmd = ""
    var pickHint = ""
    var pickTypes: [String] = []

    /// 没实现 caps 的服务会把「不认识子命令」写到 stderr —— 这里只认**整行以
    /// 子命令名开头**的行，所以那句错误文案不会被误判成一种能力。
    ///（也不能只看「首个字段等于 toggle」：`toggle: 需要参数` 这种文案会被吃进来。）
    static func parse(_ caps: String) -> Caps {
        var out = Caps()
        for rawLine in caps.split(separator: "\n") {
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            if t == "toggle" || t.hasPrefix("toggle ") || t.hasPrefix("toggle\t") {
                out.canToggle = true
                let rest = t.count > 6 ? String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) : ""
                if !rest.isEmpty { out.toggleHint = rest }
                continue
            }
            guard t == "pick" || t.hasPrefix("pick ") || t.hasPrefix("pick\t") else { continue }
            let rest = t.count > 4 ? String(t.dropFirst(4)) : ""
            let parts = rest.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            out.pickHint = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if parts.count > 1 { out.pickCmd = parts[1].trimmingCharacters(in: .whitespaces) }
            // 第三列：逗号分隔的扩展名；`*` 或不写 = 不过滤
            if parts.count > 2 {
                let raw = parts[2].trimmingCharacters(in: .whitespaces)
                if raw != "*" && !raw.isEmpty {
                    out.pickTypes = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
            }
        }
        return out
    }
}
func parseCaps(_ s: String) -> Caps { Caps.parse(s) }

// ─────────────────────────── App ───────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // lazy：--dump 模式不碰它，就不会在菜单栏闪一下
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    /// **必须并发**：refresh() 里那条「上一轮卡太久就让新一轮接手」的兜底
    /// 只有在队列能并行时才有意义 —— 串行队列上新任务只会排在卡住那轮后面，
    /// 于是 busy 还是摘不掉的闩（refreshGen 只能让旧结果作废，抢不了队列）。
    private let refreshQ = DispatchQueue(label: "deckkit.menubar.refresh", attributes: .concurrent)
    private let dumpMode = CommandLine.arguments.contains("--dump")
    private var busy = false
    private var busySince = Date.distantPast
    private var timer: Timer? = nil
    /// 每轮刷新递增；只有最新一轮的结果允许写回界面（防旧结果覆盖新结果）。
    private var refreshGen = 0
    /// 休眠/唤醒观察者。**必须持有** —— 不持有的话观察会被静默移除。
    private var sleepObservers: [NSObjectProtocol] = []

    private var online: Bool? = nil
    /// 连续探测失败了几轮。单次失败不翻「离线」，连着失败到阈值才认
    ///（见 refresh 里的判定，以及 DEBOUNCE_ROUNDS 的说明）。
    private var failStreak = 0
    private var vitals: Vitals? = nil
    private var services: [SvcLine] = []
    /// 上一轮各服务状态行的**归一化**文本（数字抹平，见 normDigits），用来判断
    /// 这一轮有没有变化。首轮只建立基线，不记 —— 没有「旧值」可对比。
    private var lastServiceLines: [String: String] = [:]
    private var lastUpdate: Date? = nil
    /// 用户刚点过服务的时间。期间跳过自愈 —— 用户的操作在终端里异步跑着，
    /// 这期间去 ensure 可能和它抢（比如挂载刚被卸载还没写进期望状态，就被自愈挂回去）。
    private var lastUserAction = Date.distantPast

    /// 并发取每个服务的一行状态（约定 §2：取 status 的第一行非空内容）。
    /// 串行时要 4×status + 4×caps 共 8 次子进程，每轮几十秒；并发只等最慢那个。
    private func collectServices() -> [SvcLine] {
        let names = serviceNames()
        var lines: [SvcLine] = []
        let lock = NSLock()
        let group = DispatchGroup()
        let cq = DispatchQueue(label: "deckkit.menubar.svc", attributes: .concurrent)
        for name in names {
            group.enter()
            cq.async {
                let entry = servicesDir + "/" + name + "/service"
                let line = firstLine(run(entry, ["status"], timeout: STATUS_TIMEOUT).out)
                let caps = parseCaps(run(entry, ["caps"], timeout: 6).out)
                let svc = SvcLine(name: name,
                                  line: line.isEmpty ? "（没有输出）" : line,
                                  canToggle: caps.canToggle,
                                  toggleHint: caps.toggleHint,
                                  pickCmd: caps.pickCmd,
                                  pickHint: caps.pickHint.isEmpty ? "选择文件" : caps.pickHint,
                                  pickTypes: caps.pickTypes)
                lock.lock(); lines.append(svc); lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return lines.sorted { $0.name < $1.name }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        menu.delegate = self
        // 日志里留个「开机」锚点：这样日志中间出现大段空白时，
        // 一眼能看出是 App 没在跑，而不是「一直在线所以没记」。
        Log.line("===== 菜单栏启动（PID \(ProcessInfo.processInfo.processIdentifier)）"
                 + " 刷新间隔 \(Int(REFRESH_SECONDS))s 防抖 \(DEBOUNCE_ROUNDS) 轮"
                 + " 日志 \(Log.path) =====")
        if let problem = deckkitRootProblem { Log.line("! \(problem)") }
        // 菜单栏里唯一会「无声过期」的状态源就是休眠/唤醒，见 observeSleepWake()。
        observeSleepWake()
        if !dumpMode {
            statusItem.menu = menu
            redrawIcon()
        }
        rebuildMenu()
        refresh()
        if dumpMode { waitAndDump(0); return }
        startTimer()
    }

    // ── 休眠 / 唤醒 ──
    // 重复 Timer 在睡眠期间完全不跑，醒来只补一次，而且还可能被唤醒后繁忙的
    // 主 run loop 再推迟一段 —— 这就是「醒来后图标状态好久才更新」的原因。
    // 系统和休眠/唤醒通知是唯一能在「刚醒」这一刻立刻重刷的手段。
    private func observeSleepWake() {
        let c = NSWorkspace.shared.notificationCenter
        let sleep = c.addObserver(forName: NSWorkspace.willSleepNotification,
                                  object: nil, queue: .main) { [weak self] _ in
            // 睡下去之后没人能再验证线上的状态：先标未知，
            // 而不是继续亮着睡前那个绿灯（它已经无法保证还成立）。
            Log.line("系统即将休眠 —— 状态置为「检测中」")
            self?.online = nil
            self?.failStreak = 0     // 睡前的失败记录不该算到醒来之后
            self?.redrawIcon()
        }
        let wake = c.addObserver(forName: NSWorkspace.didWakeNotification,
                                 object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Log.line("系统已唤醒 —— 立刻重刷（刚醒时网络常还没起来，"
                     + "这一轮失败属正常，不会立刻翻离线）")
            self.startTimer()              // 丢掉睡前那次 fire date，重新计时
            self.refresh(force: true)      // 立刻刷一次，不等下一个 tick
        }
        sleepObservers = [sleep, wake]
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: REFRESH_SECONDS, repeats: true) { [weak self] _ in
            self?.refresh(force: true)
        }
        t.tolerance = min(5, REFRESH_SECONDS * 0.1)
        // .common：菜单跟踪等模式下也不被饿死（默认的 .default 模式会）
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // ── 代跑前端 ──
    // 终端里的 `deck <服务> web start` 会写一个请求文件，再用 `open -a` 把它
    // 作为 open 事件送进来。为什么要绕这一下：这台 Mac 上 node 能不能连同网段
    // 主机，取决于**启动它的 App** 有没有 macOS「本地网络」权限 —— 终端拿不到
    // （系统设置里连条目都不生成），而本 App 有。父进程是本 App ⇒ next dev 也有。
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.lastPathComponent == "web-start.req" {
            let svc = ((try? String(contentsOf: u, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: u)
            guard !svc.isEmpty else { continue }
            // 菜单栏不能被这个动作卡住，也不能递归（DECKKIT_WEB_INAPP=1）。
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = run(deckCLI, [svc, "web", "start"], timeout: 120,
                        extraEnv: ["DECKKIT_WEB_INAPP": "1"])
                DispatchQueue.main.async { self?.refreshSoon() }
            }
        }
    }

    /// --dump：等首次刷新跑完，把菜单内容打到 stdout 就退出。
    /// 给「命令行里检查菜单会显示什么」用（菜单栏点不开时也能自检）。
    private func waitAndDump(_ n: Int) {
        if (lastUpdate == nil || busy) && n < 300 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitAndDump(n + 1) }
            return
        }
        for it in menu.items {
            if it.isSeparatorItem { print("────────"); continue }
            let title = it.attributedTitle?.string ?? it.title
            if let tip = it.toolTip { print("\(title)    ← \(tip)") } else { print(title) }
        }
        exit(0)
    }

    // 打开菜单时顺手刷新（后台跑，菜单先显示旧值）
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // ── 刷新 ──
    /// force = 定时器 / 唤醒 / 手动「立即刷新」这些「必须现在就出结果」的场合。
    /// 如果上一轮已经卡了超过 REFRESH_SECONDS + 15 秒，就让新一轮接手 ——
    /// 否则 busy 会变成摘不掉的闩，从此「立即刷新」永远失效。
    func refresh(force: Bool = false) {
        if busy {
            guard force, Date().timeIntervalSince(busySince) > REFRESH_SECONDS + 15 else { return }
            refreshGen += 1          // 作废卡住的那一轮（它的结果会被下面的 gen 检查丢掉）
        }
        busy = true
        busySince = Date()
        refreshGen += 1
        let gen = refreshGen
        refreshQ.async { [weak self] in
            guard let self = self else { return }

            // 一趟 SSH 同时拿到「在不在线」和电量/充电/温度：走 deck vitals --json，
            // 不要在线探测和遥测各来一次（那样每次刷新要等两轮）。
            let probeStart = Date()
            let telemetry = run(deckCLI, ["vitals", "--json"], timeout: 12)
            let probeDur = Date().timeIntervalSince(probeStart)
            let vit = Vitals.parse(telemetry.out)
            // 超时 ≠ 离线。醒来后第一轮探测经常是超时（网络还没起来），
            // 把它当成「离线」会让图标闪一下假红点。标「检测中…」更诚实。
            let unknown = (telemetry.code == RunOutcome.timedOut)

            // 每轮刷新都自愈一次，而不是只在启动/重连时 —— 实测挂载会在
            // Deck 一直在线的情况下自己掉（NFS 客户端超时之类），只在启动时补不够。
            //
            // 这样做安全的前提是：`ensure` 幂等，且服务会记「期望状态」
            //（files 被手动卸载后写 off），所以它不会把用户手动卸载/停掉的东西又救回来。
            // --dump 是只读自检（README 与注释都这么说）：它真去挂 NFS、
            // 真改 Mac 和 Deck 的状态，那就不是「看一眼菜单长什么样」了。
            if !self.dumpMode, vit != nil, Date().timeIntervalSince(self.lastUserAction) > 90 {
                _ = run(deckCLI, ["ensure"], timeout: 20)
            }

            let lines = self.collectServices()

            DispatchQueue.main.async {
                guard gen == self.refreshGen else { return }   // 旧结果，丢掉

                // ── 判定「在不在线」──
                //
                // 以前这里是一句 `online = unknown ? nil : (vit != nil)`：
                // **单次采样直接决定状态**，而 deck 脚本在 ssh 失败时会
                // 打印 {"online":false} 并以 rc=0 正常退出 —— 于是 5 秒的
                // ConnectTimeout 一到，一次瞬时抖动就立刻翻成「离线」，
                // 下一轮又翻回「在线」。这就是「时不时在线/离线」跳动的来源。
                //
                // 现在分两步：
                //  1) 单次失败**不立刻翻脸**，先记一笔，连续 DEBOUNCE_ROUNDS 轮
                //     都失败才认账（真断网 / 真关机必然会连着失败）；
                //  2) 但只要有一轮成功，立刻恢复「在线」并清零计数 ——
                //     恢复要快，避免网络回来了图标还红着。
                let reachable = (vit != nil)
                let decided = self.decideOnline(reachable: reachable, unknown: unknown)
                self.logHostTransition(decided: decided, reachable: reachable,
                                       unknown: unknown, telemetry: telemetry, probeDur: probeDur)
                self.logServiceChanges(lines)

                self.online = decided
                // 电量/温度等遥测只在真拿到数据时更新，避免闪成空白。
                self.vitals = reachable ? vit : (decided == false ? nil : self.vitals)
                self.services = lines
                self.lastUpdate = Date()
                self.busy = false
                self.redrawIcon()
                self.rebuildMenu()
            }
        }
    }

    /// 判定「在不在线」。分两步，见上面 refresh 里那段长注释。
    /// 返回 nil = 检测中（问不出来，既不是在线也不是离线）。
    private func decideOnline(reachable: Bool, unknown: Bool) -> Bool? {
        if reachable {
            failStreak = 0
        } else if !unknown {
            // unknown（App 自己掐的 RunOutcome.timedOut）不算失败，避免醒来第一轮误判。
            // 封顶在阈值上：日志里写「2/2」比「47/2」清楚，也够用。
            failStreak = min(failStreak + 1, DEBOUNCE_ROUNDS)
        }
        if reachable { return true }
        if unknown { return nil }                                 // 检测中…
        if failStreak >= DEBOUNCE_ROUNDS { return false }          // 连着失败，认账
        return online                                             // 观察期：维持上一次
    }

    /// 只在**状态变化**时记一条（外加观察期的抖动）。
    ///
    /// 日志记的是事件，不是心跳：正常在线时一轮不写一行 —— 否则 30 秒一行、
    /// 一天 2880 行，翻开全是「一切正常」，真事被淹掉。要留的是能回溯的：
    ///   · 状态真的变了（在线 ↔ 离线 ↔ 检测中）→ 记，这是主线
    ///   · 探测失败但还在观察期（抖动）        → 记，「时不时跳」的原始证据
    /// 已经离线还继续失败的不记：状态没有新信息，等它恢复时再记。
    private func logHostTransition(decided: Bool?, reachable: Bool, unknown: Bool,
                                   telemetry: RunResult, probeDur: TimeInterval) {
        let detail = "rc=\(telemetry.code)"
            + " 耗时=\(String(format: "%.2f", probeDur))s"
            + " 连续失败=\(failStreak)/\(DEBOUNCE_ROUNDS)"
            + " 输出=\(Log.oneline(telemetry.out.isEmpty ? "(空)" : telemetry.out))"
        if decided != online {
            let how: String
            if let d = decided { how = d ? "在线" : "离线" } else { how = "检测中" }
            Log.line("状态 → \(how)    \(detail)")
        } else if !reachable && !unknown && decided != false {
            Log.line("探测失败(未改变状态)  \(detail)")
        }
    }

    /// 服务行变化也记，但同样只记**变化**。
    ///
    /// 为什么值得记：这是主机状态之外的另一个 debug 线索 ——「files 挂载掉了」
    /// 「后端掉了」发生在哪一刻、跟主机那几行事件对不对得上，全靠它。
    /// 为什么不能直接比字符串：那一行「77,813 条索引 · 174 个节点」
    /// 每轮都在涨，直接比就成了每轮一行的心跳 —— 比较用归一化文本（见
    /// normDigits），但**记下来的是原始行**，日志里要能看见实况。
    /// 首轮没有旧值可比，只建立基线，不记。
    /// 顺带清掉已经不存在的服务的键，否则键集会一直留着一个幽灵。
    private func logServiceChanges(_ lines: [SvcLine]) {
        var seen = Set<String>()
        for svc in lines {
            seen.insert(svc.name)
            let key = normDigits(svc.line)
            if let prev = lastServiceLines[svc.name], prev != key {
                Log.line("服务 \(svc.name) → \(Log.oneline(svc.line))")
            }
            lastServiceLines[svc.name] = key
        }
        for name in lastServiceLines.keys where !seen.contains(name) {
            lastServiceLines.removeValue(forKey: name)
        }
    }

    /// 用户点完服务之后追几次刷新（终端里的动作要几十秒才落地）。
    /// 两个调用点原来各写一遍同样的魔法延迟，改一处忘一处。
    private func scheduleFollowUpRefresh(_ delays: [Double]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshSoon()
            }
        }
    }

    /// 等当前这轮刷新结束再刷（busy 时 refresh() 会直接返回）。
    private func refreshSoon(_ tries: Int = 0) {
        if busy && tries < 80 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.refreshSoon(tries + 1) }
            return
        }
        refresh()
    }

    // ── 图标 ──
    private func redrawIcon() {
        let dimmed = (online == false)
        statusItem.button?.image = logoImage(height: ICON_HEIGHT, dimmed: dimmed)
        statusItem.button?.toolTip = vitalsTooltip(vitals)
    }

    // ── 菜单 ──
    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // 标题行：状态点 + 文字
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.isEnabled = false
        let dot: String
        let color: NSColor
        switch online {
        case .some(true):  dot = "●"; color = .systemGreen
        case .some(false): dot = "●"; color = .systemRed
        case .none:        dot = "○"; color = .secondaryLabelColor
        }
        let text: String
        switch online {
        case .some(true):  text = "Steam Deck · 在线"
        case .some(false): text = "Steam Deck · 离线"
        case .none:        text = "Steam Deck · 检测中…"
        }
        let headAttr = NSMutableAttributedString()
        headAttr.append(NSAttributedString(string: dot + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: color,
        ]))
        headAttr.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ]))
        head.attributedTitle = headAttr
        menu.addItem(head)

        let stamp = lastUpdate.map { Self.timeFmt.string(from: $0) } ?? "—"
        menu.addItem(disabled("   \(deckHost)  ·  更新于 \(stamp)"))
        // 找不到仓库根目录时说清楚 —— 否则菜单只是空着，用户根本看不出原因。
        if let problem = deckkitRootProblem {
            let warnItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            warnItem.isEnabled = false
            warnItem.attributedTitle = NSAttributedString(string: "   ! " + truncate(problem, 72),
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange])
            menu.addItem(warnItem)
        }
        if let v = vitals { menu.addItem(vitalsItem(v)) }
        menu.addItem(.separator())

        menu.addItem(disabled("服务"))
        if services.isEmpty {
            menu.addItem(disabled("   （services/ 下没有可用服务）"))
        }
        for s in services {
            let it = NSMenuItem(title: s.name, action: #selector(serviceClicked(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s.name
            if !s.pickCmd.isEmpty {
                it.toolTip = "点一下\(s.pickHint)"
            } else {
                it.toolTip = s.canToggle
                    ? "点一下\(s.toggleHint)，并在终端里显示详情"
                    : "点一下在终端里显示详情"
            }
            let a = NSMutableAttributedString()
            a.append(NSAttributedString(string: s.name, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
            ]))
            a.append(NSAttributedString(string: "  " + truncate(s.line, 56), attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            it.attributedTitle = a
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let r = NSMenuItem(title: "立即刷新", action: #selector(doRefresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)

        // 终端里分两条：日常只要"游戏管理"（方向键列表），要看全量再点下面那条。
        // 括号里只写「终端」—— 括号是用来标"这条会开终端"的，
        // 操作方式在界面里自己会说（提示行就写着），不必挤进标题。
        let g = NSMenuItem(title: "游戏管理（终端）", action: #selector(openGamesTUI), keyEquivalent: "")
        g.target = self
        menu.addItem(g)

        let t = NSMenuItem(title: "完整状态（终端）", action: #selector(openTerminal), keyEquivalent: "")
        t.target = self
        menu.addItem(t)

        let o = NSMenuItem(title: "打开 deckkit 目录", action: #selector(openRoot), keyEquivalent: "")
        o.target = self
        // 根目录没找到时这个条目会打开启动磁盘（"/"），比禁用更让人困惑
        o.isEnabled = (deckkitRootProblem == nil)
        menu.addItem(o)

        menu.addItem(.separator())
        let q = NSMenuItem(title: "退出 deckkit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 第一栏里的遥测行：电量 / 充电状态 / APU 温度 / 运行时长。
    /// 菜单里只放必要项，免得把菜单撑太宽；完整读数（含电池温度、负载）在 tooltip。
    private func vitalsItem(_ v: Vitals) -> NSMenuItem {
        var parts: [String] = []
        if let c = v.capacity {
            let chg = v.chargeText
            parts.append(chg.isEmpty ? "电量 \(c)%" : "电量 \(c)% · \(chg)")
        } else if !v.chargeText.isEmpty {
            parts.append(v.chargeText)
        }
        if let t = v.apuC { parts.append(String(format: "APU %.0f°C", t)) }
        if let d = v.durationText { parts.append("已开机 \(d)") }

        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.isEnabled = false
        // 在用电池 = 一台常驻服务器靠电池跑，标黄提醒。
        let color: NSColor = v.onBattery ? .systemOrange : .secondaryLabelColor
        it.attributedTitle = NSAttributedString(
            string: "   " + parts.joined(separator: " · "),
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color])
        return it
    }

    /// 图标 tooltip：把完整读数都塞进去，鼠标一悬停就能看到。
    private func vitalsTooltip(_ v: Vitals?) -> String {
        switch online {
        case .some(true):
            guard let v = v else { return "deckkit · Steam Deck 在线（\(deckHost)）" }
            var parts: [String] = []
            if let c = v.capacity { parts.append("电量 \(c)%") }
            if !v.chargeText.isEmpty { parts.append(v.chargeText) }
            if let t = v.apuC { parts.append(String(format: "APU %.1f°C", t)) }
            if let t = v.batC { parts.append(String(format: "电池 %.1f°C", t)) }
            if let d = v.durationText { parts.append("已开机 \(d)") }
            if let l = v.load1 { parts.append(String(format: "负载 %.2f", l)) }
            return "deckkit · Deck 在线（\(deckHost)）· " + parts.joined(separator: " · ")
        case .some(false):
            return "deckkit · Steam Deck 离线（\(deckHost)）"
        case .none:
            return "deckkit · 正在检测 Steam Deck…"
        }
    }

    // ── 动作 ──
    @objc private func doRefresh() { refresh() }

    /// 点服务：声明了 toggle 的在后台直接切换主状态（files = 挂载/卸载），
    /// 其余落回「在终端里看详情」。
    /// 点服务：动作和详情都放终端里跑。
    ///
    /// 不在 App 里静默执行再弹终端 —— 有的服务切换时要等就绪（可达一分钟），
    /// 静默跑的话用户会盯着没反应的菜单栏干等。
    /// 放终端里跑，进度是实时可见的，而且用户之后还能在那个窗口继续敲。
    @objc private func serviceClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        // caps 声明了 pick 的服务：先弹 macOS 文件选择器，再把选中的文件
        // 作为参数交给它的子命令（在终端里跑，进度和报错都看得见）。
        if let svc = services.first(where: { $0.name == name }), !svc.pickCmd.isEmpty {
            // 要开模态面板：先跳一帧，别在菜单还处于 tracking 状态时弹
            //（那样面板出来了但点击/按键会被菜单吃掉）。async 一跳就出了。
            DispatchQueue.main.async { [weak self] in self?.pickAndRun(svc: svc) }
            return
        }

        let canToggle = services.first(where: { $0.name == name })?.canToggle == true
        lastUserAction = Date()      // 期间先别自愈，免得和用户的操作抢

        // 用 { } 把两条命令括起来，这样 cd 失败时不会漏到「错误目录里接着跑」
        let cmd = canToggle
            ? "{ ./bin/deck \(name) toggle; echo; ./bin/deck \(name) status; }"
            : "./bin/deck \(name) status"
        openInTerminal(cmd)

        // 终端里的动作是异步的（可能几十秒），隔一会儿追几次刷新，
        // 让菜单栏跟上终端里的结果。
        scheduleFollowUpRefresh([10.0, 45.0, 95.0])
    }

    /// 弹系统文件选择器，选中的路径交给 `deck <服务> <子命令> <路径>`。
    /// 面板的文案/过滤都来自该服务的 caps（`pick <说明>\t<子命令>\t<扩展名,..|*>），
    /// 这里不再写死成 patches 的说法（以前点 games 也会说"选择游戏补丁/挂载"）。
    private func pickAndRun(svc: SvcLine) {
        let service = svc.name
        let cmd = svc.pickCmd
        let panel = NSOpenPanel()
        panel.title = "deckkit · \(service)"
        panel.message = svc.pickHint
        panel.prompt = "运行"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true       // 纯文件夹（补丁、免安装游戏）也能选
        panel.canChooseFiles = true
        // 过滤用 UTType（`allowedFileTypes` 从 macOS 12 起弃用）。两条规矩：
        //   ① 解析不出来的扩展名直接丢；**一个都解析不出来就不设过滤**，
        //      否则面板会变成"什么都不让选"；
        //   ② 设了 allowedContentTypes 之后必须把 `.folder` 也列上 ——
        //      不列的话"选文件夹"会被系统灰掉，而 patches 的补丁文件夹、
        //      games 的免安装游戏目录都要靠选文件夹。
        if !svc.pickTypes.isEmpty {
            // caps 第三列里写 `dir`（或 `*`）才允许选文件夹 —— games 现在要求"选主程序 exe"，
            // 所以它那行不写 dir，选择器里文件夹就是灰的。
            let allowDir = svc.pickTypes.contains("*") || svc.pickTypes.contains("dir")
            panel.canChooseDirectories = allowDir
            var types = svc.pickTypes.filter { $0 != "dir" && $0 != "*" }
                .compactMap { UTType(filenameExtension: $0) }
            if allowDir { types.append(.folder) }
            if !types.isEmpty { panel.allowedContentTypes = types }
        }
        NSApp.activate(ignoringOtherApps: true)
        // 用户在面板里挑文件可能要几分钟 —— 自愈的暂停要从**弹面板之前**算起，
        // 不能等选完才记（旧写法就是这样：挑文件那几分钟里 30 秒一轮的
        // `deck ensure` 照跑，正好和马上要执行的操作抢）。
        lastUserAction = Date()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        lastUserAction = Date()                  // 选完再续一段时间
        // 单引号转义一下，路径里有空格也不会散架
        let safe = url.path.replacingOccurrences(of: "'", with: "'\\''")
        openInTerminal("{ ./bin/deck \(service) \(cmd) '\(safe)'; echo; ./bin/deck \(service) status; }")
        scheduleFollowUpRefresh([20.0, 75.0, 150.0])
    }

    /// 游戏管理：方向键操作的游戏列表（`deck games` 在终端里就是这个）
    @objc private func openGamesTUI() {
        lastUserAction = Date()
        openInTerminal("{ ./bin/deck games; }")
    }

    /// 完整状态：原来的全量 dump（`deck status` + 命令清单）
    @objc private func openTerminal() {
        lastUserAction = Date()      // 这条命令也要跑一会儿，期间同样别去自愈
        openInTerminal("{ ./bin/deck status; echo; ./bin/deck help; }")
    }

    /// 在终端里跑命令。用 Terminal 的 do script 而不是自己开 pty：
    /// 用户之后还能在那个窗口里继续敲。
    private func openInTerminal(_ cmd: String) {
        let full = "cd '\(deckkitRoot)' && \(cmd)"
        let escaped = full.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        _ = run("/usr/bin/osascript", ["-e", apple], timeout: 10)
    }

    @objc private func openRoot() {
        NSWorkspace.shared.open(URL(fileURLWithPath: deckkitRoot))
    }

    /// 退出锚点（约定 §7：生命周期要能看出「启动过 / 退出过」，都带 PID）。
    /// 只有启动锚点的话，「日志中间没东西」既可能是没事件、也可能是 App 早退了。
    /// sync：异步写在这一刻会丢（进程马上就没了）。
    func applicationWillTerminate(_ note: Notification) {
        Log.line("===== 菜单栏退出（PID \(ProcessInfo.processInfo.processIdentifier)）=====", sync: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// ─────────────────────────── 启动 ───────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
