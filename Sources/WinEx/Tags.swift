import AppKit

/// Finder tags. A file's tags live in the `com.apple.metadata:_kMDItemUserTags` extended attribute
/// as a binary plist of strings "name\n<color>", color being a Finder label index
/// (0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange).
enum FileTags {
    struct Tag: Hashable {
        let name: String
        let color: Int
    }

    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Colors of the standard tags, by their localized and English names.
    private static let standardColors: [String: Int] = [
        "Красный": 6, "Оранжевый": 7, "Желтый": 5, "Жёлтый": 5, "Зеленый": 2, "Зелёный": 2,
        "Синий": 4, "Лиловый": 3, "Фиолетовый": 3, "Серый": 1,
        "Red": 6, "Orange": 7, "Yellow": 5, "Green": 2, "Blue": 4, "Purple": 3, "Gray": 1, "Grey": 1,
    ]

    /// Finder draws tags with the system palette (the old label colors are paler).
    static func color(forIndex index: Int) -> NSColor? {
        switch index {
        case 1: .systemGray
        case 2: .systemGreen
        case 3: .systemPurple
        case 4: .systemBlue
        case 5: .systemYellow
        case 6: .systemRed
        case 7: .systemOrange
        default: nil
        }
    }

    static func tags(of url: URL) -> [Tag] {
        let data: Data? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
            return read > 0 ? buffer : nil
        }
        guard let data, let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return []
        }
        return entries.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            return Tag(name: name, color: parts.count > 1 ? Int(parts[1]) ?? 0 : standardColors[name] ?? 0)
        }
    }

    static func setTags(_ tags: [Tag], on url: URL) throws {
        let result: Int32 = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            if tags.isEmpty {
                let removed = removexattr(path, attribute, 0)
                return removed == 0 || errno == ENOATTR ? 0 : removed
            }
            let data = try PropertyListSerialization.data(
                fromPropertyList: tags.map { "\($0.name)\n\($0.color)" }, format: .binary, options: 0)
            return data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, 0) }
        }
        if result != 0 { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    /// Adds or removes one tag on every file.
    static func toggle(_ tag: Tag, on urls: [URL], add: Bool) {
        let before = Dictionary(uniqueKeysWithValues: urls.map { ($0, tags(of: $0)) })
        defer { MainActor.assumeIsolated { FileUndo.recordTags(before: before) } }
        for url in urls {
            var current = tags(of: url).filter { $0.name != tag.name }
            if add { current.append(tag) }
            do { try setTags(current, on: url) } catch { NSAlert(error: error).runModal(); return }
        }
    }

    /// Finder's favorite tags (Settings ▸ Tags), with their colors.
    static var favorites: [Tag] {
        let names = UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "FavoriteTagNames")?.filter { !$0.isEmpty }
            ?? ["Красный", "Оранжевый", "Жёлтый", "Зелёный", "Синий", "Лиловый", "Серый"]
        return names.map { Tag(name: $0, color: standardColors[$0] ?? 0) }
    }

    /// A tag named by the user: keeps the color of a known tag with that name.
    static func tag(named name: String, knownTags: [Tag]) -> Tag {
        knownTags.first { $0.name == name } ?? favorites.first { $0.name == name } ?? Tag(name: name, color: standardColors[name] ?? 0)
    }

    /// Small colored circle for menus.
    static func dotImage(color: Int, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let fill = FileTags.color(forIndex: color) {
                fill.setFill()
                path.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
    }

    /// "●● " in the tags' colors, to put before a name. Glued to it with a no-break space: a long
    /// name wraps after its own words, the dots stay on its first line (as in Finder).
    static func dots(for tags: [Tag], attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for tag in tags {
            guard let color = color(forIndex: tag.color) else { continue }
            var dot = attributes
            dot[.foregroundColor] = color
            text.append(NSAttributedString(string: "●", attributes: dot))
        }
        if text.length > 0 { text.append(NSAttributedString(string: "\u{00A0}", attributes: attributes)) }
        return text
    }

    /// macOS 26 tints folders with their tag color; do the same to a folder icon.
    static func tinted(_ icon: NSImage, with color: NSColor) -> NSImage {
        let size = NSSize(width: 256, height: 256)
        return NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            color.setFill()
            rect.fill(using: .color)  // keep the icon's shading, take the tag's hue
            color.withAlphaComponent(0.45).setFill()
            rect.fill(using: .multiply)  // deepen it: Finder's tinted folders are fully saturated
            icon.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
    }

    /// Context-menu "Теги ▸": favorites plus tags already used by the files; checkmark = every file has it.
    @MainActor
    static func menuItem(for urls: [URL], target: AnyObject, action: Selector) -> NSMenuItem {
        let fileTags = urls.map { Set(tags(of: $0).map(\.name)) }
        var all = favorites
        for tag in urls.flatMap(tags(of:)) where !all.contains(where: { $0.name == tag.name }) { all.append(tag) }
        let menu = NSMenu()
        for tag in all {
            let item = menu.addItem(withTitle: tag.name, action: action, keyEquivalent: "")
            item.target = target
            item.image = dotImage(color: tag.color)
            let count = fileTags.filter { $0.contains(tag.name) }.count
            item.state = count == 0 ? .off : (count == urls.count ? .on : .mixed)
            item.representedObject = TagToggle(tag: tag, urls: urls, add: count < urls.count)
        }
        menu.addItem(.separator())
        let edit = menu.addItem(withTitle: "Изменить теги…", action: #selector(FileListViewController.showProperties(_:)), keyEquivalent: "")
        edit.target = target
        let item = NSMenuItem(title: "Теги", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        item.submenu = menu
        return item
    }

    final class TagToggle: NSObject {
        let tag: Tag
        let urls: [URL]
        let add: Bool
        init(tag: Tag, urls: [URL], add: Bool) { self.tag = tag; self.urls = urls; self.add = add }
    }
}
