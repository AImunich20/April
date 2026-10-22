// make-icon.swift — ไอคอนแอป April: วงแหวน HUD สีเหลืองบนพื้นดำ (ธีมเหลือง-ดำเดียวกับแอป)
//   swift make-icon.swift out.png   (PNG 1024px — build.sh แปลงเป็น .icns)
import AppKit

let size: CGFloat = 1024
func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}
let amber = rgb(0xffd60a)
let hot = rgb(0xffe6c2)

let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = rect.insetBy(dx: 100, dy: 100)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    tilePath.addClip()
    NSGradient(colors: [rgb(0x1f1a14), rgb(0x0e0b08), rgb(0x060504)])!.draw(in: tile, angle: -90)
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [amber.withAlphaComponent(0.28).cgColor, amber.withAlphaComponent(0.06).cgColor,
                                   amber.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 400, options: [])

    // ขีดองศารอบนอก
    ctx.setStrokeColor(amber.withAlphaComponent(0.35).cgColor)
    for i in 0..<72 {
        let a = CGFloat(i) / 72 * .pi * 2, long = i % 6 == 0
        let r0: CGFloat = 330, r1 = r0 + (long ? 26 : 12)
        ctx.setLineWidth(long ? 5 : 3)
        ctx.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
        ctx.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
        ctx.strokePath()
    }

    // วงแหวนเป็นท่อน 3 ชั้น เรืองแสง
    ctx.setShadow(offset: .zero, blur: 30, color: amber.withAlphaComponent(0.7).cgColor)
    ctx.setLineCap(.round)
    for (r, w, a0, a1) in [(CGFloat(280), CGFloat(26), CGFloat(0.3), CGFloat(4.6)),
                            (215, 22, 2.0, 6.9), (150, 18, 4.0, 8.4)] {
        ctx.setStrokeColor(amber.cgColor)
        ctx.setLineWidth(w)
        ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.strokePath()
    }

    // แกนกลางเรืองแสง
    let core = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor.white.cgColor, hot.cgColor, amber.withAlphaComponent(0.6).cgColor,
                                   amber.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.25, 0.55, 1])!
    ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: 105, options: [])
    ctx.restoreGState()

    NSColor.white.withAlphaComponent(0.08).setStroke()
    tilePath.lineWidth = 3
    tilePath.stroke()
    return true
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
