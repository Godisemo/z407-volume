// Draws the app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
// Original artwork (SF Symbols' license doesn't allow them in app icons).
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: 824 pt body centred on a 1024 canvas, corner radius ~185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [
        NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Speaker cabinet, left of centre to leave room for the sound waves.
    let cabinet = CGRect(x: 230, y: 230, width: 360, height: 564)
    let cabinetPath = CGPath(roundedRect: cabinet, cornerWidth: 70, cornerHeight: 70, transform: nil)
    ctx.addPath(cabinetPath)
    ctx.saveGState()
    ctx.clip()
    let metal = CGGradient(colorsSpace: nil, colors: [
        NSColor(calibratedWhite: 0.93, alpha: 1).cgColor,
        NSColor(calibratedWhite: 0.70, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: 410, y: 794), end: CGPoint(x: 410, y: 230), options: [])
    ctx.restoreGState()

    func driver(center: CGPoint, radius: CGFloat) {
        let rings: [(CGFloat, CGFloat)] = [(1.0, 0.16), (0.86, 0.28), (0.40, 0.10)]
        for (scale, white) in rings {
            let r = radius * scale
            ctx.setFillColor(NSColor(calibratedWhite: white, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }
    }
    driver(center: CGPoint(x: 410, y: 385), radius: 125)   // woofer
    driver(center: CGPoint(x: 410, y: 645), radius: 62)    // tweeter

    // Volume waves.
    ctx.setLineCap(.round)
    ctx.setLineWidth(38)
    let accent = NSColor(calibratedRed: 0.35, green: 0.70, blue: 1.0, alpha: 1).cgColor
    for (i, radius) in [CGFloat(120), 205, 290].enumerated() {
        ctx.setStrokeColor(accent.copy(alpha: 1 - CGFloat(i) * 0.25)!)
        ctx.addArc(center: CGPoint(x: 560, y: 512), radius: radius,
                   startAngle: -.pi / 4.2, endAngle: .pi / 4.2, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = drawIcon(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 256).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
