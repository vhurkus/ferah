// Renders the Ferah app icon (1024×1024 PNG). Run: swift Design/make-icon.swift <out.png>
// Concept: three ledger lines on an airy teal field, each more open than the last: the space Ferah frees.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func superellipse(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...360 {
        let t = CGFloat(i) * .pi / 180
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Tile: Apple's 824pt body on a 1024 canvas, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = superellipse(in: body)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.28))
ctx.addPath(tile); ctx.setFillColor(rgb(0x2A8A7C)); ctx.fillPath()
ctx.restoreGState()

// Field: gentle top-light, like air.
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let field = CGGradient(colorsSpace: space, colors: [rgb(0x4DB8A6), rgb(0x1F7466)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(field, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Ledger lines.
let barW: CGFloat = 520, barH: CGFloat = 88, gap: CGFloat = 60
let x0 = (size - barW) / 2
let totalH = barH * 3 + gap * 2
let top = (size + totalH) / 2 - barH
func bar(_ rect: CGRect) -> CGPath { CGPath(roundedRect: rect, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil) }

// Each line is a little more open than the one above: space being freed, top to bottom.
let filled: [CGFloat] = [1.0, 0.70, 0.42]
let openGap: CGFloat = 24
for (i, fraction) in filled.enumerated() {
    let y = top - CGFloat(i) * (barH + gap)
    let w = fraction == 1 ? barW : barW * fraction
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x0B3B33, 0.25))
    ctx.addPath(bar(CGRect(x: x0, y: y, width: w, height: barH)))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    guard fraction < 1 else { continue }
    let open = CGRect(x: x0 + w + openGap, y: y, width: barW - w - openGap, height: barH).insetBy(dx: 6, dy: 6)
    ctx.addPath(bar(open).copy(strokingWithWidth: 12, lineCap: .round, lineJoin: .round, miterLimit: 1))
    ctx.setFillColor(rgb(0xFFFFFF, 0.75)); ctx.fillPath()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
