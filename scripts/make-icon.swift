// Draws the app icon (a red "K" with soft shadows on a white rounded square) and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Kleo.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func linearGradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // Tile: white rounded square with a soft drop shadow, a faint top-to-bottom gradient and a hairline edge.
    let tileRect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: rgb(0, 0, 0, 0.22))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(linearGradient([rgb(1, 1, 1), rgb(0.93, 0.94, 0.96)]),
                           start: CGPoint(x: 0, y: tileRect.maxY), end: CGPoint(x: 0, y: tileRect.minY), options: [])
    ctx.restoreGState()

    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(0, 0, 0, 0.07))
    ctx.setLineWidth(2 * s)
    ctx.strokePath()

    // The "K" as one outline: a stem and two diagonals with round caps, turned into a fillable shape.
    let strokes = CGMutablePath()
    for line in [[(388, 347), (388, 677)], [(630, 677), (433, 503)], [(513, 573), (636, 347)]] as [[(CGFloat, CGFloat)]] {
        strokes.move(to: CGPoint(x: line[0].0 * s, y: line[0].1 * s))
        strokes.addLine(to: CGPoint(x: line[1].0 * s, y: line[1].1 * s))
    }
    let letter = strokes.copy(strokingWithWidth: 96 * s, lineCap: .round, lineJoin: .round, miterLimit: 10)

    // Soft red-tinted shadow under the letter, plus a tighter darker one for depth.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22 * s), blur: 38 * s, color: rgb(0.55, 0.02, 0.06, 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 10 * s, color: rgb(0.3, 0, 0.02, 0.35))
    ctx.addPath(letter)
    ctx.setFillColor(rgb(0.86, 0.1, 0.14))
    ctx.fillPath(using: .winding)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Red gradient fill, then a light sheen on the upper half.
    ctx.saveGState()
    ctx.addPath(letter)
    ctx.clip(using: .winding)
    let box = letter.boundingBoxOfPath
    ctx.drawLinearGradient(linearGradient([rgb(1.0, 0.33, 0.34), rgb(0.88, 0.1, 0.15), rgb(0.7, 0.04, 0.1)]),
                           start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    ctx.drawLinearGradient(linearGradient([rgb(1, 1, 1, 0.28), rgb(1, 1, 1, 0)]),
                           start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.midY), options: [])
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
