// ============================================================
//  deckkit / games —— 生成「非 Steam 游戏」的封面图
//
//  Steam 给非 Steam 快捷方式的封面就是往 grid/ 目录里丢文件：
//      <appid>p.png        竖版封面（库里的大图，600×900）—— Gaming Mode 网格用的就是它
//      <appid>_header.jpg  横版头图（列表/最近游戏，460×215）
//  这个工具在 **Mac** 上把图渲染出来（Deck 上没有 AppKit），再由 service 推上去。
//
//  用法：
//    swift cover.swift --name "<游戏名>" --out <竖版.png> [--header <横版.jpg>]
//                      [--image <底图>] [--subtitle "<小字>"]
//
//  没给 --image 就画一张排版封面（深色渐变 + 标题 + Steam Deck 标记）——
//  不依赖任何素材，游戏目录里没有像样的图时也不会翻车。
// ============================================================
import AppKit

// ── 参数 ──
var args: [String: String] = [:]
var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    let k = argv[i]
    if k.hasPrefix("--") {
        let v = (i + 1 < argv.count && !argv[i + 1].hasPrefix("--")) ? argv[i + 1] : ""
        args[String(k.dropFirst(2))] = v
        i += v.isEmpty ? 1 : 2
    } else { i += 1 }
}
guard let name = args["name"], let outPath = args["out"] else {
    FileHandle.standardError.write("用法：cover.swift --name <游戏名> --out <png> [--header <jpg>] [--image <底图>] [--subtitle <小字>]\n".data(using: .utf8)!)
    exit(2)
}
let headerPath = args["header"]
let imagePath = args["image"]
let subtitle = args["subtitle"] ?? ""

// ── Steam Deck 官方 logo 的机身标记（和菜单栏那个同一段路径）──
func deckMarkPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 28.1744, y: 24.6928))
    p.addCurve(to: CGPoint(x: 12.3457, y: 8.86409),
               control1: CGPoint(x: 28.1744, y: 15.9508),
               control2: CGPoint(x: 21.0877, y: 8.86409))
    p.addLine(to: CGPoint(x: 12.3457, y: 0))
    p.addCurve(to: CGPoint(x: 37.0385, y: 24.6928),
               control1: CGPoint(x: 25.9832, y: 0),
               control2: CGPoint(x: 37.0385, y: 11.0553))
    p.addCurve(to: CGPoint(x: 12.3457, y: 49.3856),
               control1: CGPoint(x: 37.0385, y: 38.3303),
               control2: CGPoint(x: 25.9832, y: 49.3856))
    p.addLine(to: CGPoint(x: 12.3457, y: 40.5215))
    p.addCurve(to: CGPoint(x: 28.1744, y: 24.6928),
               control1: CGPoint(x: 21.0877, y: 40.5215),
               control2: CGPoint(x: 28.1744, y: 33.4348))
    p.closeSubpath()
    let r: CGFloat = 12.3464
    p.addEllipse(in: CGRect(x: 12.3464 - r, y: 24.7191 - r, width: r * 2, height: r * 2))
    return p
}
let MARK_W: CGFloat = 37.0385, MARK_H: CGFloat = 49.3856

/// 把 logo 标记画到 (x, y)，高度为 h（AppKit 坐标：y 向上）
func drawMark(_ ctx: CGContext, x: CGFloat, y: CGFloat, height: CGFloat, alpha: CGFloat) {
    let s = height / MARK_H
    ctx.saveGState()
    ctx.translateBy(x: x, y: y + height)
    ctx.scaleBy(x: s, y: -s)
    ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
    ctx.addPath(deckMarkPath())
    ctx.fillPath()
    ctx.restoreGState()
}

/// 底图：按「填满裁切」的方式画进去（不变形），再压一层从上到下变深的遮罩
func drawPhoto(_ ctx: CGContext, path: String, size: NSSize, scrim: CGFloat, overall: CGFloat) {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
    let scale = max(size.width / iw, size.height / ih)
    let dw = iw * scale, dh = ih * scale
    ctx.saveGState()
    // 截图式的居中裁切（游戏截图/立绘都能用）
    let srcW = size.width / scale, srcH = size.height / scale
    let src = CGRect(x: (iw - srcW) / 2, y: (ih - srcH) / 2, width: srcW, height: srcH)
    if let crop = cg.cropping(to: src) {
        ctx.draw(crop, in: CGRect(x: (size.width - dw) / 2, y: (size.height - dh) / 2, width: dw, height: dh))
    }
    ctx.restoreGState()
    // 整张先压一层（亮底图/截图直接用会看不清字）
    if overall > 0 {
        ctx.setFillColor(NSColor.black.withAlphaComponent(overall).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
    }
    // 再从 15% 高度往下渐隐到几乎全黑 —— 标题就压在这层里
    if scrim > 0 {
        let colors = [NSColor.black.withAlphaComponent(0).cgColor,
                      NSColor.black.withAlphaComponent(scrim).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.15, 1.0]) {
            ctx.saveGState()
            ctx.addRect(CGRect(origin: .zero, size: size))
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height),
                                   end: CGPoint(x: 0, y: 0), options: [])
            ctx.restoreGState()
        }
    }
}

/// 渐变底：深色斜向 + 一点点蓝，和 App 图标一个调子
func drawGradient(_ ctx: CGContext, size: NSSize) {
    let top = NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.24, alpha: 1).cgColor
    let bottom = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1).cgColor
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [top, bottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height),
                               end: CGPoint(x: size.width, y: 0), options: [])
    }
    // 右上角一枚很淡的高光，避免整块死黑
    if let g2 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.10).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1]) {
        ctx.drawRadialGradient(g2, startCenter: CGPoint(x: size.width * 0.85, y: size.height * 0.9),
                               startRadius: 0, endCenter: CGPoint(x: size.width * 0.85, y: size.height * 0.9),
                               endRadius: size.width * 0.75, options: [])
    }
}

/// 这个字号下标题要几行 / 多高
func measure(_ text: String, font: NSFont, width: CGFloat) -> (lines: Int, height: CGFloat) {
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
    let r = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                            attributes: attrs)
    let lh = font.ascender - font.descender + font.leading
    return (max(1, Int((r.height / lh).rounded())), r.height)
}

/// 标题排版，两类名字要分开伺候：
///   ① 短名字（OpenTTD）：**一行**，尽量大 —— 否则会断成「OpenT / TD」那种
///   ② 长名字（中文长标题）：一行会小到看不清，那就折行，取"塞得进框且不超过
///      maxLines"的最大字号
/// 判据就是「一行能做到多大」：够大（≥ oneLineMin）就用一行，否则折行。
func fitFontSize(_ text: String, font: (CGFloat) -> NSFont, box: NSSize, maxLines: Int,
                 min: CGFloat = 16, max: CGFloat = 140, oneLineMin: CGFloat = 34) -> CGFloat {
    var size = max
    while size >= min {
        let m = measure(text, font: font(size), width: box.width)
        if m.lines == 1 && m.height <= box.height {
            if size >= oneLineMin { return size }
            break
        }
        size -= 1
    }
    size = max
    while size >= min {
        let m = measure(text, font: font(size), width: box.width)
        if m.lines <= maxLines && m.height <= box.height { return size }
        size -= 1
    }
    return min
}

func drawTitle(_ ctx: CGContext, text: String, box: CGRect, size: CGFloat, align: NSTextAlignment) {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: size),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ]
    let ns = NSAttributedString(string: text, attributes: attrs)
    let g = NSGraphicsContext.current!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    ns.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
    _ = ctx
}

// ── 渲染一张 ──
func render(size: NSSize, title: String, sub: String, photo: String?, titleBox: CGRect,
            titleAlign: NSTextAlignment, mark: CGRect, maxLines: Int, scrim: CGFloat,
            out: String, jpeg: Bool) {
    // 用**显式像素尺寸**的位图上下文，不用 lockFocus：Retina 屏上 lockFocus 会按
    // backing scale 渲染成 2 倍大（实测 600×900 出来是 1200×1800），Steam 那边
    // 尺寸就不对了。
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        FileHandle.standardError.write("建位图失败\n".data(using: .utf8)!); exit(1)
    }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    if let p = photo, !p.isEmpty {
        drawPhoto(ctx, path: p, size: size, scrim: scrim, overall: 0.28)
    } else {
        drawGradient(ctx, size: size)
        // 标题上方一道短竖线（Steam 蓝），没底图时做视觉锚点
        ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.62, blue: 1.0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: titleBox.minX, y: titleBox.maxY + 22, width: 64, height: 6))
    }
    let fs = fitFontSize(title, font: { NSFont.boldSystemFont(ofSize: $0) },
                         box: titleBox.size, maxLines: maxLines,
                         oneLineMin: size.width > 500 ? 34 : 22)
    drawTitle(ctx, text: title, box: titleBox, size: fs, align: titleAlign)
    if !sub.isEmpty {
        let para = NSMutableParagraphStyle()
        para.alignment = titleAlign
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(13, fs * 0.32), weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62),
            .paragraphStyle: para,
        ]
        NSAttributedString(string: sub, attributes: attrs)
            .draw(with: CGRect(x: titleBox.minX, y: 34, width: titleBox.width, height: 60),
                  options: [.usesLineFragmentOrigin])
    }
    drawMark(ctx, x: mark.minX, y: mark.minY, height: mark.height, alpha: 0.5)
    NSGraphicsContext.restoreGraphicsState()

    let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
                    : rep.representation(using: .png, properties: [:])
    guard let d = data else { FileHandle.standardError.write("编码失败\n".data(using: .utf8)!); exit(1) }
    do { try d.write(to: URL(fileURLWithPath: out)) } catch {
        FileHandle.standardError.write("写 \(out) 失败：\(error)\n".data(using: .utf8)!); exit(1)
    }
}

// ── 竖版封面 600×900（加进库时看到的大图）──
let hasPhoto = !(imagePath ?? "").isEmpty
render(size: NSSize(width: 600, height: 900), title: name, sub: subtitle, photo: imagePath,
       titleBox: hasPhoto ? CGRect(x: 56, y: 150, width: 488, height: 400)   // 有底图：压在下半部分
                          : CGRect(x: 56, y: 300, width: 488, height: 430),  // 纯排版：居中
       titleAlign: .center,
       mark: CGRect(x: 278, y: 96, width: 44, height: 44 * MARK_H / MARK_W),
       maxLines: 5, scrim: 0.9, out: outPath, jpeg: false)

// ── 横版头图 460×215（列表 / 最近游戏）──
if let hp = headerPath, !hp.isEmpty {
    render(size: NSSize(width: 460, height: 215), title: name, sub: "", photo: imagePath,
           titleBox: hasPhoto ? CGRect(x: 28, y: 34, width: 330, height: 120)
                              : CGRect(x: 28, y: 74, width: 330, height: 110),
           titleAlign: .left,
           mark: CGRect(x: 408, y: 20, width: 26, height: 26 * MARK_H / MARK_W),
           maxLines: 3, scrim: 0.9, out: hp, jpeg: true)
}
print(outPath)
