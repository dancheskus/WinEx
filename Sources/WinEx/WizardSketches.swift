import AppKit
import UniformTypeIdentifiers

/// Small drawings for the setup wizard: what the choice on the page changes, redrawn (with a
/// cross-fade) as it's made.
class WizardSketch: NSView {
    override var isFlipped: Bool { true }

    init(size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Redraws with a short cross-fade.
    func changed() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.25
        layer?.add(fade, forKey: "fade")
        needsDisplay = true
    }

    // Shared bits

    static let folder = NSWorkspace.shared.icon(for: .folder)
    static func icon(_ type: UTType) -> NSImage { NSWorkspace.shared.icon(for: type) }

    func text(_ string: String, at point: NSPoint, size: CGFloat = 9, weight: NSFont.Weight = .regular,
              color: NSColor = .labelColor, width: CGFloat? = nil, centred: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centred ? .center : .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                         .foregroundColor: color, .paragraphStyle: paragraph]
        let height = size + 4
        let rect = NSRect(x: centred ? point.x - (width ?? 60) / 2 : point.x, y: point.y, width: width ?? 200, height: height)
        NSAttributedString(string: string, attributes: attributes).draw(in: rect)
    }

    func symbol(_ name: String, in rect: NSRect, color: NSColor = .secondaryLabelColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: rect.height, weight: .medium)) else { return }
        let tinted = NSImage(size: image.size, flipped: false) { area in
            image.draw(in: area)
            color.set()
            area.fill(using: .sourceAtop)
            return true
        }
        let size = image.size
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// An accent label with a line to what it names.
    func callout(_ string: String, from point: NSPoint, to target: NSPoint) {
        NSColor.controlAccentColor.setStroke()
        let line = NSBezierPath()
        line.move(to: point)
        line.line(to: target)
        line.lineWidth = 1
        line.stroke()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: target.x - 2.5, y: target.y - 2.5, width: 5, height: 5)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
        let label = NSAttributedString(string: string, attributes: attributes)
        let size = label.size()
        let pill = NSRect(x: point.x, y: point.y - size.height / 2 - 3, width: size.width + 14, height: size.height + 6)
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 3))
    }
}

/// An explorer window: tabs, the address bar, the command bar (if on), and files in the chosen view
/// (hidden ones too, if shown).
final class WizardWindowSketch: WizardSketch {
    var viewMode: ViewMode { didSet { changed() } }
    var commandBar: Bool { didSet { changed() } }
    var showHidden: Bool { didSet { changed() } }

    init(viewMode: ViewMode, commandBar: Bool, showHidden: Bool) {
        self.viewMode = viewMode
        self.commandBar = commandBar
        self.showHidden = showHidden
        super.init(size: NSSize(width: 560, height: 180))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var files: [(name: String, icon: NSImage, hidden: Bool, date: String, size: String)] {
        var all: [(String, NSImage, Bool, String, String)] = [
            (L("Проекты"), Self.folder, false, "12.09", "—"),
            (L("Фото"), Self.folder, false, "03.09", "—"),
            (L("Отчёт.pdf"), Self.icon(.pdf), false, "21.08", "2,4 МБ"),
            (L("План.txt"), Self.icon(.plainText), false, "14.08", "3 КБ"),
        ]
        if showHidden {
            all.insert((".config", Self.folder, true, "01.08", "—"), at: 0)
            all.append((".zshrc", Self.icon(.plainText), true, "30.07", "1 КБ"))
        }
        return all
    }

    /// A hidden file's place, tinted.
    private func mark(_ rect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    }

    /// The window's own size (the rest of the width is for the callouts).
    static let windowSize = NSSize(width: 441, height: 180)

    override func draw(_ dirtyRect: NSRect) { drawWindow(callouts: true) }

    /// The window at the origin, `windowSize` big (other sketches draw it scaled, without callouts).
    func drawWindow(callouts: Bool) {
        // The window, a little narrower than the page so the callout fits beside it
        let window = NSRect(x: 0.5, y: 0.5, width: Self.windowSize.width - 1, height: Self.windowSize.height - 1)
        let shape = NSBezierPath(roundedRect: window, xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // Tabs
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSRect(x: window.minX, y: window.minY, width: window.width, height: 24).fill()
        for (n, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(n) * 12, y: 8, width: 8, height: 8)).fill()
        }
        let tab = NSRect(x: 52, y: 4, width: 110, height: 20)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: tab, xRadius: 5, yRadius: 5).fill()
        text(L("Документы"), at: NSPoint(x: tab.minX + 8, y: tab.minY + 4), size: 9, weight: .medium)
        // Address bar
        var y: CGFloat = 28
        symbol("chevron.left", in: NSRect(x: 8, y: y + 3, width: 12, height: 10))
        symbol("chevron.right", in: NSRect(x: 22, y: y + 3, width: 12, height: 10))
        symbol("arrow.up", in: NSRect(x: 36, y: y + 3, width: 12, height: 10))
        let address = NSRect(x: 54, y: y, width: 270, height: 17)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: address, xRadius: 4, yRadius: 4).fill()
        text(L("Домашняя папка  ›  Документы"), at: NSPoint(x: address.minX + 7, y: address.minY + 3), size: 9)
        let search = NSRect(x: 330, y: y, width: 102, height: 17)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: search, xRadius: 4, yRadius: 4).fill()
        symbol("magnifyingglass", in: NSRect(x: search.minX + 4, y: y + 3, width: 12, height: 10))
        y += 22
        // Command bar
        var commandBarMid: NSPoint?
        if commandBar {
            let bar = NSRect(x: 4, y: y, width: window.width - 8, height: 20)
            if callouts {
                // Outlined only where the page is about it
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).fill()
                NSColor.controlAccentColor.setStroke()
                NSBezierPath(roundedRect: bar.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
            }
            var x = bar.minX + 8
            symbol("plus.circle", in: NSRect(x: x, y: y + 5, width: 12, height: 10), color: .controlAccentColor)
            text(L("Создать"), at: NSPoint(x: x + 14, y: y + 4), size: 9, color: .labelColor)
            x += 64
            for name in ["scissors", "doc.on.doc", "doc.on.clipboard", "pencil", "square.and.arrow.up", "trash"] {
                symbol(name, in: NSRect(x: x, y: y + 5, width: 12, height: 10))
                x += 22
            }
            symbol("arrow.up.arrow.down", in: NSRect(x: x + 8, y: y + 5, width: 12, height: 10))
            text(L("Сортировка"), at: NSPoint(x: x + 22, y: y + 4), size: 9)
            symbol("square.grid.2x2", in: NSRect(x: x + 88, y: y + 5, width: 12, height: 10))
            text(L("Вид"), at: NSPoint(x: x + 102, y: y + 4), size: 9)
            commandBarMid = NSPoint(x: bar.maxX, y: bar.midY)
            y += 24
        }
        NSColor.separatorColor.setFill()
        NSRect(x: window.minX, y: y, width: window.width, height: 1).fill()
        y += 1
        // Sidebar
        let sidebar = NSRect(x: window.minX, y: y, width: 92, height: window.maxY - y)
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        sidebar.fill()
        for (n, (name, title)) in [("house", L("Домашняя")), ("desktopcomputer", L("Рабочий стол")), ("doc", L("Документы")), ("arrow.down.circle", L("Загрузки"))].enumerated() {
            let rowY = y + 8 + CGFloat(n) * 17
            if n == 2 {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 4, y: rowY - 2, width: sidebar.width - 8, height: 15), xRadius: 4, yRadius: 4).fill()
            }
            symbol(name, in: NSRect(x: 9, y: rowY + 1, width: 11, height: 9), color: .controlAccentColor)
            text(title, at: NSPoint(x: 24, y: rowY), size: 9, width: sidebar.width - 26)
        }
        // Files
        let content = NSRect(x: sidebar.maxX + 10, y: y + 6, width: window.maxX - sidebar.maxX - 16, height: window.maxY - y - 8)
        var hiddenPoint: NSPoint?
        switch viewMode {
        case .details:
            text(L("Имя"), at: NSPoint(x: content.minX + 18, y: content.minY), size: 8, weight: .semibold, color: .secondaryLabelColor)
            text(L("Изменён"), at: NSPoint(x: content.minX + 170, y: content.minY), size: 8, weight: .semibold, color: .secondaryLabelColor)
            text(L("Размер"), at: NSPoint(x: content.minX + 250, y: content.minY), size: 8, weight: .semibold, color: .secondaryLabelColor)
            for (n, file) in files.enumerated() {
                let rowY = content.minY + 14 + CGFloat(n) * 14
                guard rowY + 12 < content.maxY else { break }
                let alpha: CGFloat = file.hidden ? 0.5 : 1
                if file.hidden { mark(NSRect(x: content.minX - 4, y: rowY - 1, width: content.width + 4, height: 14)) }
                file.icon.draw(in: NSRect(x: content.minX, y: rowY, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: alpha)
                text(file.name, at: NSPoint(x: content.minX + 18, y: rowY), size: 9, color: .labelColor.withAlphaComponent(alpha))
                text(file.date + ".2026", at: NSPoint(x: content.minX + 170, y: rowY), size: 9, color: .secondaryLabelColor)
                text(file.size, at: NSPoint(x: content.minX + 250, y: rowY), size: 9, color: .secondaryLabelColor)
                if file.hidden && hiddenPoint == nil { hiddenPoint = NSPoint(x: content.maxX, y: rowY + 6) }
            }
        case .list:
            let perColumn = max(1, Int((content.height - 4) / 18))
            for (n, file) in files.enumerated() {
                let column = n / perColumn, row = n % perColumn
                let x = content.minX + CGFloat(column) * 120, rowY = content.minY + CGFloat(row) * 18
                let alpha: CGFloat = file.hidden ? 0.5 : 1
                if file.hidden { mark(NSRect(x: x - 3, y: rowY - 2, width: 114, height: 18)) }
                file.icon.draw(in: NSRect(x: x, y: rowY, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: alpha)
                text(file.name, at: NSPoint(x: x + 19, y: rowY + 1), size: 9, color: .labelColor.withAlphaComponent(alpha), width: 96)
                if file.hidden && hiddenPoint == nil { hiddenPoint = NSPoint(x: x + 111, y: rowY + 7) }
            }
        default:
            let cell: CGFloat = 56
            let perRow = max(1, Int(content.width / cell))
            for (n, file) in files.enumerated() {
                let x = content.minX + CGFloat(n % perRow) * cell, rowY = content.minY + CGFloat(n / perRow) * 54
                guard rowY + 40 < content.maxY + 6 else { break }
                let alpha: CGFloat = file.hidden ? 0.5 : 1
                if file.hidden { mark(NSRect(x: x + 2, y: rowY - 3, width: cell - 4, height: 50)) }
                file.icon.draw(in: NSRect(x: x + 12, y: rowY, width: 32, height: 32), from: .zero, operation: .sourceOver, fraction: alpha)
                text(file.name, at: NSPoint(x: x + cell / 2, y: rowY + 34), size: 8.5, color: .labelColor.withAlphaComponent(alpha), width: cell, centred: true)
                if file.hidden && hiddenPoint == nil { hiddenPoint = NSPoint(x: x + cell - 2, y: rowY + 16) }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        shape.stroke()
        // What the switches change, named beside the window
        guard callouts else { return }
        if let point = commandBarMid { callout(L("Панель команд"), from: NSPoint(x: window.maxX + 14, y: point.y), to: point) }
        if let point = hiddenPoint { callout(L("Скрытые файлы"), from: NSPoint(x: window.maxX + 14, y: point.y), to: point) }
    }
}

/// "Только окна": WinEx's window with its context menu open (the menu is customizable).
/// "Окна и рабочий стол": WinEx's desktop — wallpaper, icons, a zone — with the window over it.
final class WizardDesktopSketch: WizardSketch {
    var replaceFinder: Bool { didSet { changed() } }
    private let explorer = WizardWindowSketch(viewMode: .mediumIcons, commandBar: true, showHidden: false)

    init(replaceFinder: Bool) {
        self.replaceFinder = replaceFinder
        super.init(size: NSSize(width: 560, height: 180))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The explorer window drawn at `origin`, `scale` times its size.
    private func drawExplorer(at origin: NSPoint, scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y)
        transform.scale(by: scale)
        transform.concat()
        explorer.drawWindow(callouts: false)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        if replaceFinder { drawDesktop() } else {
            let size = WizardWindowSketch.windowSize
            drawExplorer(at: NSPoint(x: (bounds.width - size.width) / 2, y: 0), scale: 1)
        }
    }

    /// WinEx's context menu (Windows 11 style) with «Открыть с помощью ▸» open, its top-left at `origin`.
    private func drawContextMenu(at origin: NSPoint) {
        let menu = NSRect(x: origin.x, y: origin.y, width: 138, height: 94)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        func panel(_ rect: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
        }
        panel(menu)
        // The row of buttons on top
        for (n, name) in ["scissors", "doc.on.doc", "pencil", "square.and.arrow.up", "trash"].enumerated() {
            symbol(name, in: NSRect(x: menu.minX + 10 + CGFloat(n) * 25, y: menu.minY + 6, width: 12, height: 10))
        }
        NSColor.separatorColor.setFill()
        NSRect(x: menu.minX + 7, y: menu.minY + 21, width: menu.width - 14, height: 1).fill()
        let rows: [(String, String, Bool)] = [
            ("arrow.up.forward.app", L("Открыть с помощью"), true),
            ("plus.square", L("Создать"), true),
            ("terminal", L("Открыть в терминале"), false),
            ("info.circle", L("Свойства"), false),
        ]
        for (n, row) in rows.enumerated() {
            let y = menu.minY + 25 + CGFloat(n) * 17
            if n == 0 {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: menu.minX + 4, y: y - 1, width: menu.width - 8, height: 16), xRadius: 4, yRadius: 4).fill()
            }
            symbol(row.0, in: NSRect(x: menu.minX + 9, y: y + 3, width: 11, height: 9), color: n == 0 ? .white : .secondaryLabelColor)
            text(row.1, at: NSPoint(x: menu.minX + 25, y: y + 1.5), size: 8.5, color: n == 0 ? .white : .labelColor, width: menu.width - 42)
            if row.2 { symbol("chevron.right", in: NSRect(x: menu.maxX - 15, y: y + 4, width: 7, height: 7), color: n == 0 ? .white : .tertiaryLabelColor) }
        }
        // «Открыть с помощью ▸»: its programs, chosen in Settings ▸ Программы
        let apps = ["/System/Applications/Preview.app", "/System/Applications/TextEdit.app", "/Applications/Visual Studio Code.app"]
            .filter { FileManager.default.fileExists(atPath: $0) }.prefix(3)
        let sub = NSRect(x: menu.maxX - 3, y: menu.minY + 20, width: 100, height: CGFloat(apps.count) * 17 + 8)
        panel(sub)
        for (n, path) in apps.enumerated() {
            let y = sub.minY + 5 + CGFloat(n) * 17
            NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: sub.minX + 8, y: y, width: 13, height: 13))
            text(FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                 at: NSPoint(x: sub.minX + 25, y: y + 1.5), size: 8.5, width: sub.width - 30)
        }
        callout(L("Меню настраивается"), from: NSPoint(x: sub.minX + 6, y: menu.minY - 16), to: NSPoint(x: sub.minX + 30, y: sub.minY))
    }

    private func drawDesktop() {
        let size = WizardWindowSketch.windowSize
        let screen = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: screen, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.25, blue: 0.48, alpha: 1), NSColor(srgbRed: 0.55, green: 0.42, blue: 0.52, alpha: 1)])?
            .draw(in: screen, angle: -70)
        // Menu bar
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: 14).fill()
        symbol("apple.logo", in: NSRect(x: 8, y: 3, width: 10, height: 8), color: .white)
        text("WinEx", at: NSPoint(x: 24, y: 1.5), size: 8, weight: .bold, color: .white)
        // A zone: only WinEx's desktop has them
        let zone = NSRect(x: 18, y: 24, width: 140, height: 72)
        let path = NSBezierPath(roundedRect: zone, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.3).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        path.stroke()
        text(L("Работа"), at: NSPoint(x: zone.midX, y: zone.minY + 4), size: 8.5, weight: .semibold, color: .white, width: zone.width, centred: true)
        for n in 0..<3 {
            Self.icon(n == 1 ? .pdf : .plainText).draw(in: NSRect(x: zone.minX + 12 + CGFloat(n) * 44, y: zone.minY + 24, width: 26, height: 26))
        }
        // Icons outside it, under it
        for (n, (name, icon)) in [(L("Проекты"), Self.folder), (L("Фото"), Self.folder)].enumerated() {
            let x = zone.minX + 6 + CGFloat(n) * 52
            icon.draw(in: NSRect(x: x + 7, y: 112, width: 26, height: 26))
            text(name, at: NSPoint(x: x + 20, y: 139), size: 7.5, weight: .medium, color: .white, width: 60, centred: true)
        }
        // The window over the desktop, a right click in it
        let scale: CGFloat = 0.56
        let origin = NSPoint(x: 176, y: 42)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: origin, size: NSSize(width: size.width * scale, height: size.height * scale)), xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        drawExplorer(at: origin, scale: scale)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        shape.stroke()
        drawContextMenu(at: NSPoint(x: 322, y: 70))
        callout(L("Зоны WinEx"), from: NSPoint(x: 110, y: 164), to: NSPoint(x: 120, y: 96))
    }
}

/// Zones on WinEx's desktop: a zone of icons and a folder portal (or, switched off, the same icons
/// loose on the wallpaper).
final class WizardZonesSketch: WizardSketch {
    var zonesOn: Bool { didSet { changed() } }

    init(zonesOn: Bool) {
        self.zonesOn = zonesOn
        super.init(size: NSSize(width: 560, height: 180))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func zone(_ rect: NSRect, title: String, portal: Bool = false) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.black.withAlphaComponent(0.3).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        path.stroke()
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 20), xRadius: 9, yRadius: 9).fill()
        symbol("chevron.down", in: NSRect(x: rect.minX + 8, y: rect.minY + 6, width: 8, height: 8), color: .white.withAlphaComponent(0.7))
        text(title, at: NSPoint(x: rect.midX, y: rect.minY + 4), size: 9, weight: .semibold, color: .white, width: rect.width - 40, centred: true)
        if portal { symbol("arrow.up.right.square", in: NSRect(x: rect.maxX - 18, y: rect.minY + 5, width: 11, height: 10), color: .white.withAlphaComponent(0.8)) }
    }

    private func icon(_ image: NSImage, _ name: String, at point: NSPoint) {
        image.draw(in: NSRect(x: point.x - 14, y: point.y, width: 28, height: 28))
        text(name, at: NSPoint(x: point.x, y: point.y + 29), size: 7.5, weight: .medium, color: .white, width: 62, centred: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        let screen = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: screen, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.25, blue: 0.48, alpha: 1), NSColor(srgbRed: 0.55, green: 0.42, blue: 0.52, alpha: 1)])?
            .draw(in: screen, angle: -70)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: 14).fill()
        symbol("apple.logo", in: NSRect(x: 8, y: 3, width: 10, height: 8), color: .white)
        text("WinEx", at: NSPoint(x: 24, y: 1.5), size: 8, weight: .bold, color: .white)
        let work: [(NSImage, String)] = [(Self.icon(.pdf), L("Отчёт.pdf")), (Self.icon(.plainText), L("План.txt")), (Self.folder, L("Проекты"))]
        let downloads: [(NSImage, String)] = [(Self.icon(.zip), "archive.zip"), (Self.icon(.png), "photo.png"), (Self.icon(.pdf), "invoice.pdf")]
        if zonesOn {
            let workZone = NSRect(x: 24, y: 28, width: 190, height: 92)
            zone(workZone, title: L("Работа"))
            for (n, item) in work.enumerated() { icon(item.0, item.1, at: NSPoint(x: workZone.minX + 34 + CGFloat(n) * 61, y: workZone.minY + 28)) }
            let portal = NSRect(x: 250, y: 28, width: 190, height: 92)
            zone(portal, title: L("Загрузки"), portal: true)
            for (n, item) in downloads.enumerated() { icon(item.0, item.1, at: NSPoint(x: portal.minX + 34 + CGFloat(n) * 61, y: portal.minY + 28)) }
            // A rolled-up one: just its title
            zone(NSRect(x: 24, y: 136, width: 190, height: 20), title: L("Архив"))
        } else {
            // The same icons, loose
            for (n, item) in (work + downloads).enumerated() {
                icon(item.0, item.1, at: NSPoint(x: 60 + CGFloat(n % 3) * 76, y: 28 + CGFloat(n / 3) * 52))
            }
        }
        for (n, item) in [(Self.folder, L("Фото"))].enumerated() {
            icon(item.0, item.1, at: NSPoint(x: screen.maxX - 34, y: 26 + CGFloat(n) * 46))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        shape.stroke()
        if zonesOn {
            callout(L("Зона"), from: NSPoint(x: 232, y: 146), to: NSPoint(x: 200, y: 120))
            callout(L("Портал папки"), from: NSPoint(x: 458, y: 140), to: NSPoint(x: 430, y: 120))
            callout(L("Свёрнутая"), from: NSPoint(x: 232, y: 168), to: NSPoint(x: 214, y: 146))
        }
    }
}
