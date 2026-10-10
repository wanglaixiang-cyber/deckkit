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
//                      [--icon <exe 里抠出来的图标.png>]   # 渐变按图标主色上色 + 居中放这枚图标
//                      [--icon-fill]                      # 改成把图标铺满整张
//                      [--image <底图>]                    # 用别的图铺满
//                      [--subtitle "<小字>"]
//
//  没有图时退回纯排版封面（中性深色渐变 + 标题）。
// ============================================================
import AppKit

// ── 参数 ──
var args: [String: String] = [:]
var flags = Set<String>()
let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    let k = argv[i]
    if k.hasPrefix("--") {
        let key = String(k.dropFirst(2))
        if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") {
            args[key] = argv[i + 1]
            i += 2
        } else {
            flags.insert(key)
            i += 1
        }
    } else { i += 1 }
}
guard let name = args["name"], let outPath = args["out"] else {
    FileHandle.standardError.write("用法：cover.swift --name <游戏名> --out <png> [--header <jpg>] [--icon <png>] [--icon-fill] [--image <底图>] [--subtitle <小字>]\n".data(using: .utf8)!)
    exit(2)
}
let headerPath = args["header"]
let iconPath = args["icon"]
let imagePath = args["image"]
let iconFill = flags.contains("icon-fill")
let subtitle = args["subtitle"] ?? ""

// 底图/图标三选一：--image 铺满 > --icon-fill 铺满（用图标）> --icon 居中放图标
struct Look {
    var fill: String? = nil        // 铺满整张的图
    var icon: String? = nil        // 居中放的那枚图标
    var tintFrom: String? = nil    // 渐变取色来源
}
var look = Look()
if let img = imagePath, !img.isEmpty {
    look.fill = img
} else if let ic = iconPath, !ic.isEmpty {
    if iconFill {
        look.fill = ic
    } else {
        look.icon = ic
        look.tintFrom = ic
    }
}
let hasFill = !(look.fill ?? "").isEmpty
let hasIcon = !(look.icon ?? "").isEmpty

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

/// 铺满：按「填满裁切」的方式画（不变形），再压一层整体变暗 + 底部渐隐
func drawFill(_ ctx: CGContext, path: String, size: NSSize, overall: CGFloat, scrim: CGFloat) {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
    let scale = max(size.width / iw, size.height / ih)
    let dw = iw * scale, dh = ih * scale
    let srcW = size.width / scale, srcH = size.height / scale
    let src = CGRect(x: (iw - srcW) / 2, y: (ih - srcH) / 2, width: srcW, height: srcH)
    if let crop = cg.cropping(to: src) {
        ctx.draw(crop, in: CGRect(x: (size.width - dw) / 2, y: (size.height - dh) / 2,
                                 width: dw, height: dh))
    }
    if overall > 0 {
        ctx.setFillColor(NSColor.black.withAlphaComponent(overall).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
    }
    if scrim > 0 {
        let colors = [NSColor.black.withAlphaComponent(0).cgColor,
                      NSColor.black.withAlphaComponent(scrim).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                              locations: [0.15, 1.0]) {
            ctx.saveGState()
            ctx.addRect(CGRect(origin: .zero, size: size))
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height),
                                   end: CGPoint(x: 0, y: 0), options: [])
            ctx.restoreGState()
        }
    }
}

/// 图标的「主色」：缩到 1×1 取平均（先铺黑底，免得透明区让颜色偏淡）
func averageColor(_ path: String) -> NSColor? {
    guard let img = NSImage(contentsOfFile: path),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    img.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1), from: .zero,
             operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.colorAt(x: 0, y: 0)
}

/// 背景渐变：中性深色；给了图标就按图标主色上色（不要那种纯灰）
func drawGradient(_ ctx: CGContext, size: NSSize, tintFrom: String?) {
    var top = NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.24, alpha: 1)
    var bottom = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1)
    if let p = tintFrom, let c = averageColor(p) {
        let h = c.hueComponent
        let s = min(1.0, max(0.30, c.saturationComponent * 1.7))
        let b = max(0.20, min(0.52, c.brightnessComponent * 0.95))
        top = NSColor(calibratedHue: h, saturation: s * 0.85, brightness: b, alpha: 1)
        bottom = NSColor(calibratedHue: h, saturation: s, brightness: 0.07, alpha: 1)
    }
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height),
                               end: CGPoint(x: size.width, y: 0), options: [])
    }
    if let g2 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.10).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1]) {
        ctx.drawRadialGradient(g2, startCenter: CGPoint(x: size.width * 0.5, y: size.height * 0.72),
                               startRadius: 0,
                               endCenter: CGPoint(x: size.width * 0.5, y: size.height * 0.72),
                               endRadius: size.width * 0.8, options: [])
    }
}

/// 把图标居中放上去（带一点投影）；边长按源图算 —— 64px 的小图标不硬拉大
func drawIcon(_ ctx: CGContext, path: String, center: CGPoint, maxSide: CGFloat) {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let src = CGFloat(max(cg.width, cg.height))
    let side = min(maxSide, max(170, src * 1.8))
    let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: rect)
    ctx.restoreGState()
}

// ── 标题排版 ──
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

/// 短名字保持一行尽量大；长名字折行取「塞得进框」的最大字号
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

func drawTitle(_ text: String, box: CGRect, size: CGFloat, align: NSTextAlignment) {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: size),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ]
    NSAttributedString(string: text, attributes: attrs)
        .draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

// ── 渲染一张 ──
func render(size: NSSize, title: String, sub: String, look: Look, titleBox: CGRect,
            titleAlign: NSTextAlignment, mark: CGRect, iconCenter: CGPoint, iconMax: CGFloat,
            maxLines: Int, out: String, jpeg: Bool) {
    // 显式像素尺寸的位图上下文：Retina 上 lockFocus 会渲染成 2 倍大（实测）
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

    if let f = look.fill, !f.isEmpty {
        drawFill(ctx, path: f, size: size, overall: 0.28, scrim: 0.9)
    } else {
        drawGradient(ctx, size: size, tintFrom: look.tintFrom)
    }
    if let ic = look.icon, !ic.isEmpty {
        drawIcon(ctx, path: ic, center: iconCenter, maxSide: iconMax)
    }
    let fs = fitFontSize(title, font: { NSFont.boldSystemFont(ofSize: $0) },
                         box: titleBox.size, maxLines: maxLines,
                         oneLineMin: size.width > 500 ? 34 : 22)
    drawTitle(title, box: titleBox, size: fs, align: titleAlign)
    if !sub.isEmpty {
        let para = NSMutableParagraphStyle()
        para.alignment = titleAlign
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(13, fs * 0.32), weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62),
            .paragraphStyle: para,
        ]
        NSAttributedString(string: sub, attributes: attrs)
            .draw(with: CGRect(x: titleBox.minX, y: 30, width: titleBox.width, height: 60),
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

// ── 竖版封面 600×900 ──
render(size: NSSize(width: 600, height: 900), title: name, sub: subtitle, look: look,
       // 铺满底图 → 标题压在下半；放图标 → 标题让到下方、图标占中间；纯排版 → 居中
       titleBox: hasFill ? CGRect(x: 56, y: 140, width: 488, height: 380)
                : hasIcon ? CGRect(x: 56, y: 110, width: 488, height: 300)
                          : CGRect(x: 56, y: 300, width: 488, height: 430),
       titleAlign: .center,
       mark: CGRect(x: 278, y: 52, width: 44, height: 44 * MARK_H / MARK_W),
       iconCenter: CGPoint(x: 300, y: 610), iconMax: 360,
       maxLines: 5, out: outPath, jpeg: false)

// ── 横版头图 460×215 ──
if let hp = headerPath, !hp.isEmpty {
    render(size: NSSize(width: 460, height: 215), title: name, sub: "", look: look,
           titleBox: hasIcon ? CGRect(x: 28, y: 56, width: 250, height: 110)
                    : hasFill ? CGRect(x: 28, y: 34, width: 330, height: 120)
                              : CGRect(x: 28, y: 74, width: 330, height: 110),
           titleAlign: .left,
           mark: CGRect(x: 408, y: 12, width: 26, height: 26 * MARK_H / MARK_W),
           iconCenter: CGPoint(x: 372, y: 110), iconMax: 130,
           maxLines: 3, out: hp, jpeg: true)
}
print(outPath)
