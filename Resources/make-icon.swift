// Generates Resources/AppIcon.icns: a yellow Explorer-style folder on a light squircle.
// Run from the repo root: swift Resources/make-icon.swift
// The artwork fills Apple's icon grid (824 pt squircle on a 1024 canvas) so macOS 26 shows it
// as is instead of putting it on a gray backdrop.
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // Squircle background
    let squircle = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.93, green: 0.96, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.74, green: 0.84, blue: 0.97, alpha: 1))!.draw(in: squircle, angle: -90)

    // Folder: back panel with tab, then the front panel
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 212, y: 262))
    back.line(to: NSPoint(x: 212, y: 700))
    back.curve(to: NSPoint(x: 252, y: 740), controlPoint1: NSPoint(x: 212, y: 722), controlPoint2: NSPoint(x: 230, y: 740))
    back.line(to: NSPoint(x: 420, y: 740))
    back.curve(to: NSPoint(x: 462, y: 718), controlPoint1: NSPoint(x: 438, y: 740), controlPoint2: NSPoint(x: 450, y: 732))
    back.line(to: NSPoint(x: 492, y: 682))
    back.line(to: NSPoint(x: 772, y: 682))
    back.curve(to: NSPoint(x: 812, y: 642), controlPoint1: NSPoint(x: 794, y: 682), controlPoint2: NSPoint(x: 812, y: 664))
    back.line(to: NSPoint(x: 812, y: 262))
    back.close()
    NSGradient(starting: NSColor(red: 0.93, green: 0.66, blue: 0.13, alpha: 1),
               ending: NSColor(red: 0.98, green: 0.78, blue: 0.25, alpha: 1))!.draw(in: back, angle: 90)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let front = NSBezierPath(roundedRect: NSRect(x: 196, y: 230, width: 632, height: 420), xRadius: 40, yRadius: 40)
    NSColor(red: 0.99, green: 0.80, blue: 0.27, alpha: 1).setFill()
    front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 1.0, green: 0.84, blue: 0.33, alpha: 1),
               ending: NSColor(red: 1.0, green: 0.90, blue: 0.52, alpha: 1))!.draw(in: front, angle: 90)

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
