// 用三位 AI 娘的立绘合成 App 图标（1024×1024 PNG）。
// 用法：swift tools/make_icon.swift web/sprites build/icon_1024.png
import AppKit

let spritesDir = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let size = 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// macOS 图标网格：824×824 圆角矩形，四周留 100px
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 22
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(calibratedRed: 0.08, green: 0.07, blue: 0.14, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.19, green: 0.16, blue: 0.34, alpha: 1),
                    NSColor(calibratedRed: 0.07, green: 0.06, blue: 0.13, alpha: 1)])?.draw(in: tile, angle: -90)

func glow(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, at center: NSPoint, radius: CGFloat) {
    let c = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    NSGradient(colors: [c.withAlphaComponent(0.5), c.withAlphaComponent(0)])?
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}
glow(0.85, 0.47, 0.34, at: NSPoint(x: 300, y: 380), radius: 290)  // Claude 橙
glow(0.06, 0.64, 0.50, at: NSPoint(x: 724, y: 380), radius: 290)  // ChatGPT 绿
glow(0.56, 0.49, 0.94, at: NSPoint(x: 512, y: 520), radius: 330)  // Gemini 紫

func draw(_ rel: String, _ rect: NSRect) {
    NSImage(contentsOfFile: "\(spritesDir)/\(rel)")?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}
// 合影站位：Gemini娘后排居中，Claude娘 / GPT娘前排两侧
draw("gemini/default/idle.png", NSRect(x: 247, y: 318, width: 530, height: 530))
draw("claude/v2/idle.png", NSRect(x: 92, y: 118, width: 430, height: 430))
draw("gpt/v2/idle.png", NSRect(x: 502, y: 118, width: 430, height: 430))
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
