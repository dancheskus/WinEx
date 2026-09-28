import AppKit
import UniformTypeIdentifiers

/// macOS 26 folder customization (Finder ▸ "Настроить папку…"): a symbol or an emoji on the folder,
/// stored as JSON in the `com.apple.icon.folder#S` extended attribute — `{"sym":"star.fill"}` or
/// `{"emoji":"🐱"}`. The folder's color comes from its last colored tag.
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
        // Finder also marks the folder as having its own icon: then macOS draws it customized
        // everywhere (Dock, Open dialogs, other apps). Left alone if it has a real custom icon file
        let iconFile = url.appendingPathComponent("Icon\r")
        if value != nil || !FileManager.default.fileExists(atPath: iconFile.path) {
            setHasCustomIcon(value != nil, at: url)
        }
        // Let Finder / Dock redraw the folder
        NSWorkspace.shared.noteFileSystemChanged(url.path)
    }

    /// Finder's "has a custom icon" flag (kHasCustomIcon in the FinderInfo attribute).
    static func setHasCustomIcon(_ on: Bool, at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let name = "com.apple.FinderInfo"
            var info = Data(count: 32)
            let size = info.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, 32, 0, 0) }
            if size != 32 { info = Data(count: 32) }
            let before = info[8]
            info[8] = on ? before | 0x04 : before & ~0x04
            guard info[8] != before else { return }
            if info.allSatisfy({ $0 == 0 }) {
                removexattr(path, name, 0)
            } else {
                _ = info.withUnsafeBytes { setxattr(path, name, $0.baseAddress, 32, 0, 0) }
            }
        }
    }
}

/// Folder icons exactly as macOS 26 Finder draws them: in the color of the last colored tag, with
/// the symbol / emoji on the front, and with a sheet of paper showing when the folder isn't empty.
/// macOS draws that itself for a folder marked as having its own icon; WinEx lets it draw small
/// sample folders of its own (in its caches) with the same tag and customization, and uses their
/// icons — nothing is written to the user's folders just to show them.
enum FolderIcon {
    /// `nil` when the system's own icon is right (a special folder, a folder with its own picture).
    static func icon(for url: URL, tagColor: Int?, customization: FolderCustomization?) -> NSImage? {
        guard tagColor != nil || customization != nil || isPlain(url) else { return nil }
        return render(tagColor: tagColor, customization: customization, filled: hasContents(url))
    }

    /// The icon of a folder with this tag color (`FileTags` color index), customization and contents.
    static func render(tagColor: Int?, customization: FolderCustomization?, filled: Bool) -> NSImage {
        let key = "\(tagColor ?? 0)-\(filled ? 1 : 0)-" + customizationKey(customization)
        // (Folder listings load icons off the main thread)
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[key] { return known }
        let image = sample(key: key, tagColor: tagColor, customization: customization, filled: filled).map {
            NSWorkspace.shared.icon(forFile: $0.path)
        } ?? NSWorkspace.shared.icon(for: .folder)
        cache[key] = image
        return image
    }

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    private static func customizationKey(_ customization: FolderCustomization?) -> String {
        switch customization {
        case .symbol(let name): "s" + name.replacingOccurrences(of: ".", with: "_")   // no dots: not taken for an extension
        case .emoji(let emoji): "e" + emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_")
        case nil: "none"
        }
    }

    /// A sample folder (made once) for macOS to draw.
    private static func sample(key: String, tagColor: Int?, customization: FolderCustomization?, filled: Bool) -> URL? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let looks = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "WinEx").appendingPathComponent("Folder looks")
        let folder = looks.appendingPathComponent(key)
        if fm.fileExists(atPath: folder.path) { return folder }
        // Made complete elsewhere, then copied in: macOS keeps the look a folder had when it first
        // saw it, so it must never see one half made
        let draft = looks.appendingPathComponent(".draft-" + UUID().uuidString)
        defer { try? fm.removeItem(at: draft) }
        do {
            try fm.createDirectory(at: draft, withIntermediateDirectories: true)
            if filled { try Data().write(to: draft.appendingPathComponent("sheet")) }
            if let tagColor { try FileTags.setTags([FileTags.Tag(name: "WinEx", color: tagColor)], on: draft) }
            // Without a symbol or emoji an invisible emoji: macOS then draws just the colored folder
            try FolderCustomization.write(customization ?? .emoji(" "), to: draft)
            try fm.copyItem(at: draft, to: folder)
            return folder
        } catch {
            return fm.fileExists(atPath: folder.path) ? folder : nil
        }
    }

    /// Folders not empty (hidden files don't count) show a sheet of paper, as in Finder.
    static func hasContents(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let dir = opendir(path) else { return false }
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                let first = withUnsafeBytes(of: entry.pointee.d_name) { $0.first ?? 0 }
                if first != UInt8(ascii: ".") { return true }
            }
            return false
        }
    }

    /// An ordinary folder: not one with a picture of its own (Downloads' arrow, a volume, a folder
    /// with its own icon) — those keep the system's icon.
    private static func isPlain(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isVolumeKey, .isPackageKey])
        if values?.isVolume == true || values?.isPackage == true { return false }
        if specialFolders.contains(url.standardizedFileURL.path) { return false }
        if url.path.hasPrefix(cloudStorage) { return url.deletingLastPathComponent().path != cloudStorage }
        // Its own icon (the "custom icon" flag set, no customization)
        let flagged: Bool = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            var info = [UInt8](repeating: 0, count: 32)
            return getxattr(path, "com.apple.FinderInfo", &info, 32, 0, 0) == 32 && info[8] & 0x04 != 0
        }
        return !flagged
    }

    private static let cloudStorage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage").path

    private static let specialFolders: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Public/Drop Box",
                     "Library", "Applications", "Sites", ".Trash", "Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage"]
            .map { home.appendingPathComponent($0).path }
        paths += [home.path, "/", "/Applications", "/Applications/Utilities", "/Library", "/System", "/Users", "/Users/Shared",
                  "/Volumes", "/Network", "/System/Applications", "/System/Applications/Utilities"]
        return Set(paths)
    }()
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
        super.init(frame: NSRect(x: 0, y: 0, width: max(width, 220), height: 46))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// With the mouse on a circle, a line under them says what a click will do (Finder: «Добавить
    /// тег «Зеленый»»). With an item right under the row («Настроить папку…») the line takes its
    /// place — the item shows the text instead of its own — so nothing moves; otherwise the row
    /// keeps room for it.
    weak var captionItem: NSMenuItem? {
        didSet { setFrameSize(NSSize(width: frame.width, height: captionItem == nil ? 46 : 28)) }
    }
    private var captionItemTitle: NSAttributedString?

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
        guard let item = captionItem else { return }
        if captionItemTitle == nil { captionItemTitle = item.attributedTitle }
        guard let index, let base = captionItemTitle else {
            item.attributedTitle = captionItemTitle
            return
        }
        item.attributedTitle = Self.caption(caption(for: index), in: base)
    }

    private func caption(for index: Int) -> String {
        counts[index] == urls.count ? L("Удалить тег «%@»", tags[index].name) : L("Добавить тег «%@»", tags[index].name)
    }

    /// The item's (decorated) title with the caption, dimmed, for its text and no icon.
    private static func caption(_ caption: String, in title: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: title)
        // The text: what follows the attachments (icon, strut) and the spaces after them
        let string = result.string as NSString
        var start = 0
        while start < string.length, let scalar = UnicodeScalar(string.character(at: start)),
              scalar == "\u{FFFC}" || scalar == " " { start += 1 }
        let tab = string.range(of: "\t", range: NSRange(location: start, length: string.length - start))
        let end = tab.location == NSNotFound ? string.length : tab.location
        result.replaceCharacters(in: NSRange(location: start, length: end - start), with: caption)
        result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: start, length: (caption as NSString).length))
        // The icon: an empty picture of the same size
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: start)) { value, range, stop in
            guard let icon = value as? NSTextAttachment, icon.bounds.width > 1 else { return }
            let blank = NSTextAttachment()
            blank.image = NSImage(size: icon.bounds.size)
            blank.bounds = icon.bounds
            result.addAttribute(.attachment, value: blank, range: range)
            stop.pointee = true
        }
        return result
    }

    private func circleRect(_ index: Int) -> NSRect {
        NSRect(x: Self.inset + CGFloat(index) * (Self.diameter + Self.spacing), y: bounds.height - 6 - Self.diameter,
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
            let color = FileTags.color(forIndex: tag.color) ?? .gray
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            // A thin darker rim, as Finder draws them
            let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            rim.lineWidth = 1
            (color.shadow(withLevel: 0.25) ?? color).setStroke()
            rim.stroke()
            let mark = NSBezierPath()
            mark.lineWidth = 2
            mark.lineCapStyle = .round
            // Under the mouse: what a click does — «+» adds, «×» removes (every file has it)
            if hovered == i {
                let r = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)
                if counts[i] == urls.count {
                    mark.move(to: NSPoint(x: r.minX, y: r.minY)); mark.line(to: NSPoint(x: r.maxX, y: r.maxY))
                    mark.move(to: NSPoint(x: r.minX, y: r.maxY)); mark.line(to: NSPoint(x: r.maxX, y: r.minY))
                } else {
                    mark.move(to: NSPoint(x: r.midX, y: r.minY)); mark.line(to: NSPoint(x: r.midX, y: r.maxY))
                    mark.move(to: NSPoint(x: r.minX, y: r.midY)); mark.line(to: NSPoint(x: r.maxX, y: r.midY))
                }
                NSColor.white.setStroke()
                mark.stroke()
                continue
            }
            guard counts[i] > 0 else { continue }
            // ✓ when every file has the tag, – when only some do
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
        // The caption: what a click on the circle under the mouse will do
        guard captionItem == nil, let i = hovered, tags.indices.contains(i) else { return }
        NSAttributedString(string: caption(for: i), attributes: [
            .font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(at: NSPoint(x: Self.inset, y: 3))
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        FileTags.toggle(tags[i], on: urls, add: counts[i] < urls.count)
        setHovered(nil)
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
