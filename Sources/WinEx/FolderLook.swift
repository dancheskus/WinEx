import AppKit
import UniformTypeIdentifiers

/// macOS 26 folder customization (Finder ▸ "Настроить папку…"): a symbol or an emoji on the folder,
/// stored as JSON in the `com.apple.icon.folder#S` extended attribute — `{"sym":"star.fill"}` or
/// `{"emoji":"🐱"}`. The folder's color comes from its first colored tag.
enum FolderCustomization: Equatable {
    case symbol(String)
    case emoji(String)

    private static let attribute = "com.apple.icon.folder#S"

    static func read(_ url: URL) -> FolderCustomization? {
        let data: Data? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
            return read > 0 ? buffer : nil
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let symbol = json["sym"] as? String, !symbol.isEmpty { return .symbol(symbol) }
        if let emoji = json["emoji"] as? String, !emoji.isEmpty { return .emoji(emoji) }
        return nil
    }

    /// `nil` removes the customization.
    static func write(_ value: FolderCustomization?, to url: URL) throws {
        let result: Int32 = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            guard let value else {
                let removed = removexattr(path, attribute, 0)
                return removed == 0 || errno == ENOATTR ? 0 : removed
            }
            let json: [String: String] = switch value {
            case .symbol(let name): ["sym": name]
            case .emoji(let emoji): ["emoji": emoji]
            }
            let data = try JSONSerialization.data(withJSONObject: json)
            return data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, 0) }
        }
        if result != 0 { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        // Let Finder / Dock redraw the folder
        NSWorkspace.shared.noteFileSystemChanged(url.path)
    }
}

/// Draws folder icons the way macOS 26 Finder does: tinted with the first colored tag,
/// with the customization symbol / emoji on the front.
enum FolderIcon {
    private static let genericFolder = NSWorkspace.shared.icon(for: .folder)

    /// `nil` when the folder has nothing special (use the system icon, which keeps special-folder glyphs).
    static func custom(tagColor: NSColor?, customization: FolderCustomization?) -> NSImage? {
        guard tagColor != nil || customization != nil else { return nil }
        return render(tagColor: tagColor, customization: customization)
    }

    static func render(tagColor: NSColor?, customization: FolderCustomization?) -> NSImage {
        let base = tagColor.map { FileTags.tinted(genericFolder, with: $0) } ?? genericFolder
        guard let customization else { return base }
        let side: CGFloat = 256
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            // The front panel of the folder occupies roughly the lower 60 % of the icon
            let badge = NSRect(x: rect.width * 0.34, y: rect.height * 0.2, width: rect.width * 0.32, height: rect.height * 0.32)
            switch customization {
            case .symbol(let name):
                let config = NSImage.SymbolConfiguration(pointSize: badge.height * 0.8, weight: .medium)
                guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { break }
                // Embossed look: the folder's own color, a shade darker
                let ink = (tagColor ?? NSColor(red: 0.16, green: 0.49, blue: 0.87, alpha: 1)).blended(withFraction: 0.35, of: .black) ?? .black
                let tinted = NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r)
                    ink.setFill()
                    r.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: DesktopView.aspectFit(tinted.size, in: badge), from: .zero, operation: .sourceOver, fraction: 0.85)
            case .emoji(let emoji):
                let font = NSFont.systemFont(ofSize: badge.height * 0.85)
                let text = NSAttributedString(string: emoji, attributes: [.font: font])
                let size = text.size()
                text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
            }
            return true
        }
    }
}

// MARK: - Inline tag row for context menus

/// Finder's row of colored circles at the top of the context menu: click toggles the tag
/// on every target file; a checkmark means all of them have it.
final class TagRowMenuView: NSView {
    private let tags = FileTags.favorites.filter { $0.color > 0 }
    private let urls: [URL]
    private let onChange: () -> Void
    private var hovered: Int?
    private static let diameter: CGFloat = 18, spacing: CGFloat = 8, inset: CGFloat = 20

    init(urls: [URL], onChange: @escaping () -> Void) {
        self.urls = urls
        self.onChange = onChange
        let width = Self.inset * 2 + CGFloat(tags.count) * Self.diameter + CGFloat(max(tags.count - 1, 0)) * Self.spacing
        super.init(frame: NSRect(x: 0, y: 0, width: max(width, 220), height: 30))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func circleRect(_ index: Int) -> NSRect {
        NSRect(x: Self.inset + CGFloat(index) * (Self.diameter + Self.spacing), y: (bounds.height - Self.diameter) / 2,
               width: Self.diameter, height: Self.diameter)
    }

    private func index(at point: NSPoint) -> Int? {
        tags.indices.first { circleRect($0).insetBy(dx: -3, dy: -3).contains(point) }
    }

    /// How many of the files carry each tag.
    private var counts: [Int] {
        let fileTags = urls.map { Set(FileTags.tags(of: $0).map(\.name)) }
        return tags.map { tag in fileTags.filter { $0.contains(tag.name) }.count }
    }

    override func draw(_ dirtyRect: NSRect) {
        let counts = counts
        for (i, tag) in tags.enumerated() {
            var rect = circleRect(i)
            if hovered == i { rect = rect.insetBy(dx: -2, dy: -2) }
            FileTags.color(forIndex: tag.color)?.setFill()
            NSBezierPath(ovalIn: rect).fill()
            guard counts[i] > 0 else { continue }
            // ✓ when every file has the tag, – when only some do
            let mark = NSBezierPath()
            mark.lineWidth = 2
            mark.lineCapStyle = .round
            if counts[i] == urls.count {
                mark.move(to: NSPoint(x: rect.minX + rect.width * 0.28, y: rect.midY))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.32))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.7))
            } else {
                mark.move(to: NSPoint(x: rect.minX + rect.width * 0.3, y: rect.midY))
                mark.line(to: NSPoint(x: rect.maxX - rect.width * 0.3, y: rect.midY))
            }
            NSColor.white.setStroke()
            mark.stroke()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let index = index(at: convert(event.locationInWindow, from: nil))
        if index != hovered { hovered = index; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        FileTags.toggle(tags[i], on: urls, add: counts[i] < urls.count)
        needsDisplay = true
        onChange()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    /// The menu item hosting the row.
    static func menuItem(for urls: [URL]) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = TagRowMenuView(urls: urls) {
            NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
        }
        return item
    }
}
