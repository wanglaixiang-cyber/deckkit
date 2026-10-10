// ============================================================
//  deckkit —— 生成 App 图标（menubar/AppIcon.icns 的素材）
//
//  用法：swift menubar/makeicon.swift <输出目录>
//        → 在输出目录里写 master.png（1024×1024，圆角深色底 + 官方 logo 标记）
//        再由 build.sh 用 sips 缩成 .iconset、iconutil 打成 .icns。
//
//  为什么用代码画：仓库里不放二进制素材，会员的机器上也不用装设计工具 ——
//  这段路径就是从 main.swift 菜单栏图标里原样搬过来的（官方 logo 的机身标记）。
// ============================================================
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S: CGFloat = 1024

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// 底：深色圆角方块（macOS 的图标形状，留白按系统惯例 ~9%）
let inset = S * 0.09
let rect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1),
])!
grad.draw(in: bg, angle: -90)

// 官方 logo 的机身标记（viewBox 里 x∈[0,37.04]、y∈[0,49.39]）
let markW: CGFloat = 37.0385
let markH: CGFloat = 49.3856
if let ctx = NSGraphicsContext.current?.cgContext {
    let target = S * 0.50                       // 标记高度占画布一半
    let s = target / markH
    let dx = (S - markW * s) / 2
    let dy = (S - target) / 2
    ctx.saveGState()
    ctx.translateBy(x: dx, y: dy + target)      // SVG 的 y 轴朝下，先翻过来
    ctx.scaleBy(x: s, y: -s)

    let path = CGMutablePath()
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
    let r: CGFloat = 12.3464
    path.addEllipse(in: CGRect(x: 12.3464 - r, y: 24.7191 - r, width: r * 2, height: r * 2))

    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("生成 PNG 失败\n".data(using: .utf8)!)
    exit(1)
}
let out = (outDir as NSString).appendingPathComponent("master.png")
do {
    try png.write(to: URL(fileURLWithPath: out))
    print(out)
} catch {
    FileHandle.standardError.write("写 \(out) 失败：\(error)\n".data(using: .utf8)!)
    exit(1)
}
