// Generates Resources/AppIcon.icns: Windows Explorer's folder (yellow, with the blue band across
// its front) on a deep blue squircle with a glassy light from the top, macOS 26 style.
// Run from the repo root: swift Resources/make-icon.swift
// The artwork fills Apple's icon grid (824 pt squircle on a 1024 canvas) so macOS 26 shows it
// as is instead of putting it on a gray backdrop.
import AppKit

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform(); t.scale(by: size / 1024); t.concat()

    let box = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)
    NSGradient(colors: [c(38, 132, 255), c(16, 84, 214), c(10, 52, 160)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: squircle, angle: -90)
    // Glass: a soft light from the top
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.25).setStroke()
    let rim = NSBezierPath(roundedRect: box.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183); rim.lineWidth = 4; rim.stroke()

    // Folder back with tab
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 232, y: 300))
    back.line(to: NSPoint(x: 232, y: 690))
    back.curve(to: NSPoint(x: 270, y: 728), controlPoint1: NSPoint(x: 232, y: 711), controlPoint2: NSPoint(x: 249, y: 728))
    back.line(to: NSPoint(x: 420, y: 728))
    back.curve(to: NSPoint(x: 458, y: 708), controlPoint1: NSPoint(x: 436, y: 728), controlPoint2: NSPoint(x: 447, y: 721))
    back.line(to: NSPoint(x: 486, y: 674))
    back.line(to: NSPoint(x: 754, y: 674))
    back.curve(to: NSPoint(x: 792, y: 636), controlPoint1: NSPoint(x: 775, y: 674), controlPoint2: NSPoint(x: 792, y: 657))
    back.line(to: NSPoint(x: 792, y: 300))
    back.close()
    NSGradient(starting: c(226, 150, 20), ending: c(246, 186, 52))!.draw(in: back, angle: 90)

    // Front panel
    let front = NSBezierPath(roundedRect: NSRect(x: 214, y: 270, width: 596, height: 368), xRadius: 38, yRadius: 38)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.shadowBlurRadius = 30
    NSGraphicsContext.saveGraphicsState(); shadow.set(); c(255, 206, 70).setFill(); front.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: c(255, 196, 46), ending: c(255, 226, 120))!.draw(in: front, angle: 90)
    // Explorer's blue band across the front
    NSGraphicsContext.saveGraphicsState()
    front.addClip()
    let band = NSRect(x: 214, y: 336, width: 596, height: 74)
    NSGradient(starting: c(20, 110, 235), ending: c(60, 160, 255))!.draw(in: band, angle: 0)
    // top highlight line of the front
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSRect(x: 214, y: 630, width: 596, height: 8).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: CGFloat(base * factor)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
