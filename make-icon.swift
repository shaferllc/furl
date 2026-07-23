#!/usr/bin/env swift
// Generates AppIcon.icns for Furl — nautical: a furled sail lashed to its yard
// on a mast, pennant flying, moonlit waves below. Furl (v.): to roll up a sail.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: size * x, y: size * y) }

    // Rounded-tile background: deep ocean-night gradient (house style).
    let corner = size * 0.22
    let tile = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04),
                            xRadius: corner, yRadius: corner)
    tile.addClip()
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.01, green: 0.04, blue: 0.10, alpha: 1),
    ])!
    grad.draw(in: rect, angle: -90)

    // Moon, upper left.
    let moonC = pt(0.24, 0.78)
    let moonR = size * 0.055
    NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.88, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: moonC.x - moonR, y: moonC.y - moonR,
                                width: moonR * 2, height: moonR * 2)).fill()

    // Waves: two smooth swells across the bottom.
    for (y, alpha, phase) in [(0.19, 0.35, 0.0), (0.12, 0.20, 0.5)] {
        let wave = NSBezierPath()
        wave.lineWidth = size * 0.022
        wave.lineCapStyle = .round
        let amp = size * 0.030
        let seg = size * 0.24
        var x = size * -0.02 + seg * phase
        wave.move(to: NSPoint(x: x, y: size * y))
        while x < size {
            wave.curve(to: NSPoint(x: x + seg, y: size * y),
                       controlPoint1: NSPoint(x: x + seg * 0.33, y: size * y + amp),
                       controlPoint2: NSPoint(x: x + seg * 0.67, y: size * y - amp))
            x += seg
        }
        NSColor(calibratedRed: 0.45, green: 0.75, blue: 0.95, alpha: alpha).setStroke()
        wave.stroke()
    }

    let wood = NSColor(calibratedRed: 0.78, green: 0.60, blue: 0.40, alpha: 1)
    let woodDark = NSColor(calibratedRed: 0.62, green: 0.46, blue: 0.30, alpha: 1)

    // Mast.
    let mastW = size * 0.045
    let mast = NSBezierPath(roundedRect: NSRect(x: size * 0.50 - mastW / 2, y: size * 0.26,
                                                width: mastW, height: size * 0.60),
                            xRadius: mastW / 2, yRadius: mastW / 2)
    wood.setFill()
    mast.fill()

    // Pennant at the masthead, streaming right.
    let pennant = NSBezierPath()
    pennant.move(to: pt(0.52, 0.845))
    pennant.curve(to: pt(0.78, 0.80),
                  controlPoint1: pt(0.62, 0.855), controlPoint2: pt(0.71, 0.835))
    pennant.curve(to: pt(0.52, 0.765),
                  controlPoint1: pt(0.70, 0.775), controlPoint2: pt(0.60, 0.755))
    pennant.close()
    NSColor(calibratedRed: 0.35, green: 0.78, blue: 1.0, alpha: 1).setFill()
    pennant.fill()

    // Yard (the horizontal spar the sail hangs from).
    let yardH = size * 0.032
    let yard = NSBezierPath(roundedRect: NSRect(x: size * 0.15, y: size * 0.615,
                                                width: size * 0.70, height: yardH),
                            xRadius: yardH / 2, yRadius: yardH / 2)
    woodDark.setFill()
    yard.fill()

    // Furled sail: a plump canvas roll slung under the yard, sagging between
    // its lashings like a real furled square sail.
    let sailTop = size * 0.615
    let sailBottom = size * 0.47
    let sail = NSBezierPath()
    sail.move(to: NSPoint(x: size * 0.17, y: sailTop))
    // Three sagging scallops along the bottom edge.
    let xs: [CGFloat] = [0.17, 0.39, 0.61, 0.83]
    sail.line(to: NSPoint(x: size * 0.17, y: sailBottom + size * 0.045))
    for i in 0..<3 {
        let x0 = xs[i], x1 = xs[i + 1]
        sail.curve(to: NSPoint(x: size * x1, y: sailBottom + size * 0.045),
                   controlPoint1: NSPoint(x: size * (x0 + 0.07), y: sailBottom - size * 0.035),
                   controlPoint2: NSPoint(x: size * (x1 - 0.07), y: sailBottom - size * 0.035))
    }
    sail.line(to: NSPoint(x: size * 0.83, y: sailTop))
    sail.close()
    let canvas = NSGradient(colors: [
        NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.84, alpha: 1),
        NSColor(calibratedRed: 0.78, green: 0.73, blue: 0.62, alpha: 1),
    ])!
    canvas.draw(in: sail, angle: -90)

    // Lashings: dark ties where the sail gathers.
    NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.32, alpha: 0.9).setStroke()
    for x in [0.39, 0.61] {
        let tie = NSBezierPath()
        tie.lineWidth = size * 0.020
        tie.lineCapStyle = .round
        tie.move(to: NSPoint(x: size * (x - 0.012), y: sailTop + size * 0.01))
        tie.line(to: NSPoint(x: size * (x + 0.012), y: sailBottom + size * 0.025))
        tie.stroke()
    }

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, _ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    let img = drawIcon(size: CGFloat(px))
    try! png(img, px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print("Wrote AppIcon.icns")
