// ============================================================
//  deckkit —— 框架级菜单栏 App
//
//  图标用 Steam Deck 官方 logo 的「机身标记」（不含 STEAM DECK 字样），
//  以 template image 渲染：自动适配浅色/深色菜单栏，Deck 离线时压暗。
//
//  菜单内容：
//    · Steam Deck 状态（在线/离线 + 主机名 + 上次刷新时间）
//    · 各服务的一行状态（来自 services/<名字>/service status 的第一行）
//    · 刷新 / 在终端看完整状态 / 打开 deckkit 目录 / 退出
//
//  约定（docs/约定.md §5）：绝不在主线程做同步网络调用 —— 所有探测都在
//  后台队列上跑，并带超时；结果回到主线程再重建菜单。
// ============================================================
import Cocoa

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

// SSH 别名由 bin/deck 自己从 DECKKIT_DECK_SSH / 默认值决定，这里只管显示用的主机名。
let deckHost = ProcessInfo.processInfo.environment["DECKKIT_DECK_HOST"] ?? "steamdeck.local"

let ICON_HEIGHT: CGFloat = 16
/// 刷新间隔。每轮要开 6~8 个 SSH 连接，靠 ControlMaster 复用后一轮约 0.3 秒
///（复用前约 2.6 秒），所以 30 秒一次很便宜。
let REFRESH_SECONDS: TimeInterval = 30
let STATUS_TIMEOUT: TimeInterval = 20

// ─────────────────────────── 子进程执行 ───────────────────────────
struct RunResult { let code: Int32; let out: String }

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

    do { try p.run() } catch { return RunResult(code: -1, out: "") }

    // 后台读干管道，避免子进程输出超过管道缓冲区时卡死。
    var data = Data()
    let readDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        readDone.signal()
    }

    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        p.waitUntilExit()
        exited.signal()
    }

    if exited.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = exited.wait(timeout: .now() + 2)
        return RunResult(code: -2, out: "")
    }
    // 读端还没结束（子进程留下了占着管道的孙进程）时不再读 data ——
    // 那会和后台写线程抢同一个变量。宁可放弃输出。
    if readDone.wait(timeout: .now() + 2) == .timedOut {
        return RunResult(code: p.terminationStatus, out: "")
    }
    return RunResult(code: p.terminationStatus, out: String(data: data, encoding: .utf8) ?? "")
}

// ─────────────────────────── 文本工具 ───────────────────────────
func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
}

/// 取第一行非空内容 —— 与 bin/deck 概览的取法一致（约定 §2）。
func firstLine(_ s: String) -> String {
    for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = stripANSI(String(raw)).trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { return line }
    }
    return ""
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
    var onBattery: Bool { ac == false }

    var durationText: String? {
        guard let s = uptimeS, s > 0 else { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)分钟"
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

// ─────────────────────────── App ───────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // lazy：--dump 模式不碰它，就不会在菜单栏闪一下
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let refreshQ = DispatchQueue(label: "deckkit.menubar.refresh")
    private let dumpMode = CommandLine.arguments.contains("--dump")
    private var busy = false
    private var busySince = Date.distantPast
    private var timer: Timer? = nil
    /// 每轮刷新递增；只有最新一轮的结果允许写回界面（防旧结果覆盖新结果）。
    private var refreshGen = 0
    /// 休眠/唤醒观察者。**必须持有** —— 不持有的话观察会被静默移除。
    private var sleepObservers: [NSObjectProtocol] = []

    private var online: Bool? = nil
    private var vitals: Vitals? = nil
    private var services: [SvcLine] = []
    private var lastUpdate: Date? = nil
    /// 用户刚点过服务的时间。期间跳过自愈 —— 用户的操作在终端里异步跑着，
    /// 这期间去 ensure 可能和它抢（比如挂载刚被卸载还没写进期望状态，就被自愈挂回去）。
    private var lastUserAction = Date.distantPast

    /// 并发取每个服务的一行状态（约定 §2：取 status 的第一行非空内容）。
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
                let r = run(entry, ["status"], timeout: STATUS_TIMEOUT)
                let line = firstLine(r.out)
                // 顺带问一下能力：caps 每行是「子命令 [说明]」，
                // 声明了 toggle 的服务，点一下是「切换」而不是「看详情」。
                // 没实现 caps 的服务会把「不认识子命令」写到 stderr，这里按整行
                // 取第一个字段匹配，所以那句错误文案不会被误判成能力。
                let caps = run(entry, ["caps"], timeout: 6).out
                var canToggle = false
                var toggleHint = "切换状态"
                for rawLine in caps.split(separator: "\n") {
                    let fields = rawLine.trimmingCharacters(in: .whitespaces)
                        .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard let cmd = fields.first, cmd == "toggle" else { continue }
                    canToggle = true
                    if fields.count > 1 {
                        toggleHint = String(fields[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
                var pickCmd = ""
                var pickHint = ""
                var pickTypes: [String] = []
                for rawLine in caps.split(separator: "\n") {
                    let t = rawLine.trimmingCharacters(in: .whitespaces)
                    guard t == "pick" || t.hasPrefix("pick ") || t.hasPrefix("pick\t") else { continue }
                    let rest = t.count > 4 ? String(t.dropFirst(4)) : ""
                    let parts = rest.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    pickHint = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if parts.count > 1 { pickCmd = parts[1].trimmingCharacters(in: .whitespaces) }
                    // 第三列：逗号分隔的扩展名；`*` 或不写 = 不过滤
                    if parts.count > 2 {
                        let raw = parts[2].trimmingCharacters(in: .whitespaces)
                        if raw != "*" && !raw.isEmpty {
                            pickTypes = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        }
                    }
                }
                lock.lock()
                lines.append(SvcLine(name: name,
                                     line: line.isEmpty ? "（没有输出）" : line,
                                     canToggle: canToggle,
                                     toggleHint: toggleHint,
                                     pickCmd: pickCmd,
                                     pickHint: pickHint.isEmpty ? "选择文件" : pickHint,
                                     pickTypes: pickTypes))
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return lines.sorted { $0.name < $1.name }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        menu.delegate = self
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
            self?.online = nil
            self?.redrawIcon()
        }
        let wake = c.addObserver(forName: NSWorkspace.didWakeNotification,
                                 object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
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
            let telemetry = run(deckCLI, ["vitals", "--json"], timeout: 12)
            let vit = Vitals.parse(telemetry.out)
            // 超时 ≠ 离线。醒来后第一轮探测经常是超时（网络还没起来），
            // 把它当成「离线」会让图标闪一下假红点。标「检测中…」更诚实。
            let unknown = (telemetry.code == -2)

            // 每轮刷新都自愈一次，而不是只在启动/重连时 —— 实测挂载会在
            // Deck 一直在线的情况下自己掉（NFS 客户端超时之类），只在启动时补不够。
            //
            // 这样做安全的前提是：`ensure` 幂等，且服务会记「期望状态」
            //（files 被手动卸载后写 off），所以它不会把用户手动卸载/停掉的东西又救回来。
            if vit != nil && Date().timeIntervalSince(self.lastUserAction) > 90 {
                _ = run(deckCLI, ["ensure"], timeout: 20)
            }

            let lines = self.collectServices()

            DispatchQueue.main.async {
                guard gen == self.refreshGen else { return }   // 旧结果，丢掉
                self.online = unknown ? nil : (vit != nil)
                self.vitals = unknown ? nil : vit
                self.services = lines
                self.lastUpdate = Date()
                self.busy = false
                self.redrawIcon()
                self.rebuildMenu()
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

        let t = NSMenuItem(title: "在终端里查看完整状态", action: #selector(openTerminal), keyEquivalent: "")
        t.target = self
        menu.addItem(t)

        let o = NSMenuItem(title: "打开 deckkit 目录", action: #selector(openRoot), keyEquivalent: "")
        o.target = self
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
            pickAndRun(svc: svc)
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
        for delay in [10.0, 45.0, 95.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshSoon()
            }
        }
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
        if !svc.pickTypes.isEmpty { panel.allowedFileTypes = svc.pickTypes }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        lastUserAction = Date()                  // 期间别自愈
        // 单引号转义一下，路径里有空格也不会散架
        let safe = url.path.replacingOccurrences(of: "'", with: "'\\''")
        openInTerminal("{ ./bin/deck \(service) \(cmd) '\(safe)'; echo; ./bin/deck \(service) status; }")
        for delay in [20.0, 75.0, 150.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshSoon()
            }
        }
    }

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

    @objc private func quit() { NSApp.terminate(nil) }
}

// ─────────────────────────── 启动 ───────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
