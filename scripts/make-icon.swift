// Draws the app icon (a red padlock marked with a white "K", on a gray tile) and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Kleo.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Tile: dark graphite rounded square with a soft drop shadow and a faint light edge.
    let tileRect = r(100, 100, 824, 824)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0.3, 0.31, 0.35))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.46, 0.48, 0.53), rgb(0.29, 0.3, 0.34)]),
                           start: CGPoint(x: 0, y: tileRect.maxY), end: CGPoint(x: 0, y: tileRect.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.1))
    ctx.setLineWidth(2 * s)
    ctx.strokePath()

    // Shackle: a U of brushed metal behind the body.
    let u = CGMutablePath()
    u.move(to: CGPoint(x: 377 * s, y: 540 * s))
    u.addLine(to: CGPoint(x: 377 * s, y: 650 * s))
    u.addArc(center: CGPoint(x: 512 * s, y: 650 * s), radius: 135 * s, startAngle: .pi, endAngle: 0, clockwise: true)
    u.addLine(to: CGPoint(x: 647 * s, y: 540 * s))
    let shackle = u.copy(strokingWithWidth: 62 * s, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 12 * s, color: rgb(0, 0, 0, 0.5))
    ctx.addPath(shackle)
    ctx.setFillColor(rgb(0.7, 0.72, 0.76))
    ctx.fillPath(using: .winding)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shackle)
    ctx.clip(using: .winding)
    ctx.drawLinearGradient(gradient([rgb(0.55, 0.57, 0.62), rgb(0.96, 0.97, 0.99), rgb(0.72, 0.74, 0.78), rgb(0.5, 0.52, 0.57)],
                                    [0, 0.35, 0.65, 1]),
                           start: CGPoint(x: 330 * s, y: 0), end: CGPoint(x: 694 * s, y: 0), options: [])
    ctx.restoreGState()

    // Body: glossy red rounded block with a deep shadow.
    let bodyRect = r(277, 214, 470, 380)
    let body = CGPath(roundedRect: bodyRect, cornerWidth: 78 * s, cornerHeight: 78 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22 * s), blur: 40 * s, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0.8, 0.08, 0.12))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(1, 0.36, 0.36), rgb(0.88, 0.1, 0.15), rgb(0.62, 0.03, 0.08)], [0, 0.45, 1]),
                           start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.minY), options: [])
    // Glossy band across the top third.
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.3), rgb(1, 1, 1, 0)]),
                           start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.maxY - 150 * s), options: [])
    ctx.restoreGState()
    let inner = CGPath(roundedRect: bodyRect.insetBy(dx: 3 * s, dy: 3 * s), cornerWidth: 75 * s, cornerHeight: 75 * s, transform: nil)
    ctx.addPath(inner)
    ctx.setStrokeColor(rgb(1, 0.75, 0.75, 0.35))
    ctx.setLineWidth(3 * s)
    ctx.strokePath()

    // White "K" on the body, with a small shadow so it reads as engraved.
    let k = CGMutablePath()
    let t = CGAffineTransform(translationX: 512 * s, y: 400 * s).scaledBy(x: 0.52, y: 0.52).translatedBy(x: -505 * s, y: -512 * s)
    for line in [[(388, 347), (388, 677)], [(630, 677), (433, 503)], [(513, 573), (636, 347)]] as [[(CGFloat, CGFloat)]] {
        k.move(to: CGPoint(x: line[0].0 * s, y: line[0].1 * s), transform: t)
        k.addLine(to: CGPoint(x: line[1].0 * s, y: line[1].1 * s), transform: t)
    }
    let letter = k.copy(strokingWithWidth: 96 * 0.52 * s, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -5 * s), blur: 8 * s, color: rgb(0.35, 0, 0.03, 0.6))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(letter)
    ctx.setFillColor(rgb(1, 1, 1))
    ctx.fillPath(using: .winding)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: CGFloat(base * scale)).write(to: out.appendingPathComponent(name))
    }
}
