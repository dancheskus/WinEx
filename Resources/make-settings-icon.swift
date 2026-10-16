// Generates Resources/WinExSettings.icns: the document icon of WinEx settings files — a page with
// a folded corner (macOS 26 style), WinEx's icon on it, "WINEX" under it.
// Run from the repo root: swift Resources/make-settings-icon.swift
import AppKit

let appIcon = NSImage(contentsOfFile: "Resources/AppIcon.icns")!

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform(); t.scale(by: size / 1024); t.concat()

    // The page: 704 × 880 in the middle of the canvas, the top-right corner folded
    let page = NSRect(x: 160, y: 72, width: 704, height: 880), fold: CGFloat = 200, r: CGFloat = 56
    let outline = NSBezierPath()
    outline.move(to: NSPoint(x: page.minX + r, y: page.minY))
    outline.line(to: NSPoint(x: page.maxX - r, y: page.minY))
    outline.curve(to: NSPoint(x: page.maxX, y: page.minY + r), controlPoint1: NSPoint(x: page.maxX, y: page.minY), controlPoint2: NSPoint(x: page.maxX, y: page.minY))
    outline.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    outline.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    outline.line(to: NSPoint(x: page.minX + r, y: page.maxY))
    outline.curve(to: NSPoint(x: page.minX, y: page.maxY - r), controlPoint1: NSPoint(x: page.minX, y: page.maxY), controlPoint2: NSPoint(x: page.minX, y: page.maxY))
    outline.line(to: NSPoint(x: page.minX, y: page.minY + r))
    outline.curve(to: NSPoint(x: page.minX + r, y: page.minY), controlPoint1: NSPoint(x: page.minX, y: page.minY), controlPoint2: NSPoint(x: page.minX, y: page.minY))
    outline.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.white.setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0.82, alpha: 1).setStroke()
    outline.lineWidth = 6
    outline.stroke()
    // The fold
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    flap.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold + 36))
    flap.curve(to: NSPoint(x: page.maxX - fold + 36, y: page.maxY - fold),
               controlPoint1: NSPoint(x: page.maxX - fold, y: page.maxY - fold), controlPoint2: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
    flap.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    flap.close()
    NSColor(white: 0.9, alpha: 1).setFill()
    flap.fill()
    NSColor(white: 0.8, alpha: 1).setStroke()
    flap.lineWidth = 6
    flap.stroke()

    // WinEx's icon, and the name under it
    appIcon.draw(in: NSRect(x: 512 - 210, y: 390, width: 420, height: 420))
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    NSAttributedString(string: "WINEX", attributes: [
        .font: NSFont.systemFont(ofSize: 92, weight: .semibold), .foregroundColor: NSColor(white: 0.55, alpha: 1), .kern: 6, .paragraphStyle: paragraph,
    ]).draw(in: NSRect(x: page.minX, y: 180, width: page.width, height: 120))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WinExSettings.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/WinExSettings.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Resources/WinExSettings.icns" : "iconutil failed")
