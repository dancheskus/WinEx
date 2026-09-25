import AppKit

/// Desktop "View ▸" icon sizes, as in Explorer.
enum DesktopIconSize: Int, CaseIterable {
    case large, medium, small

    var title: String {
        switch self {
        case .large: "Крупные значки"
        case .medium: "Обычные значки"
        case .small: "Мелкие значки"
        }
    }

    var iconSide: CGFloat {
        switch self {
        case .large: 96
        case .medium: 64
        case .small: 40
        }
    }

    /// Grid cell: icon plus a two-line label.
    var cellSize: NSSize {
        switch self {
        case .large: NSSize(width: 124, height: 140)
        case .medium: NSSize(width: 100, height: 106)
        case .small: NSSize(width: 84, height: 80)
        }
    }
}

/// Desktop "Sort by ▸" keys.
enum DesktopSortKey: String, CaseIterable {
    case name, size, type, date

    var title: String {
        switch self {
        case .name: "Имя"
        case .size: "Размер"
        case .type: "Тип элемента"
        case .date: "Дата изменения"
        }
    }
}

/// Icon positions and view options of the WinEx desktop, persisted in user defaults.
/// A position is the icon center as fractions of its monitor (y from the top), so it survives
/// resolution changes — the same convention Finder uses — plus the monitor it's on.
@MainActor
final class DesktopLayout {
    private struct Stored: Codable {
        var positions: [String: [Double]] = [:]
        var iconSize = DesktopIconSize.medium.rawValue
        var autoArrange = false
        var alignToGrid = true
        var showIcons = true
        var sortKey = DesktopSortKey.name.rawValue
        var importedFromFinder = false
        /// File name → display UUID of the monitor it's on (none: the main monitor).
        var screens: [String: String]?
    }

    /// Where an icon is: center as fractions of the monitor, and the monitor (nil: the main one).
    struct Place: Equatable {
        var point: CGPoint
        var screenID: String?
    }

    /// A connected monitor, main first: its display UUID and size.
    struct Screen {
        var id: String
        var size: CGSize
    }

    private static let defaultsKey = "desktopLayout"
    private var stored: Stored

    init(desktop: URL, screens: [Screen]) {
        if let data = AppDefaults.store.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
        if !stored.importedFromFinder {
            // First run (or after a reset): take the arrangement and view options the user has in Finder
            var screenIDs: [String: String] = [:]
            for (name, place) in FinderDesktopLayout.iconPlaces(in: desktop, screenSizes: screens.map(\.size)) {
                stored.positions[name] = [place.point.x, place.point.y]
                // Finder numbers monitors in the system's order, main first
                if place.screen > 0, screens.indices.contains(place.screen) { screenIDs[name] = screens[place.screen].id }
            }
            stored.screens = screenIDs
            let options = FinderDesktopLayout.viewOptions(
                UserDefaults(suiteName: "com.apple.finder")?.dictionary(forKey: "DesktopViewSettings"))
            stored.iconSize = options.iconSize.rawValue
            stored.alignToGrid = options.alignToGrid
            stored.autoArrange = options.autoArrange
            stored.sortKey = options.sortKey.rawValue
            stored.importedFromFinder = true
            save()
        }
    }

    /// Forgets everything WinEx changed on the desktop; the next `DesktopLayout` takes Finder's again.
    static func forget() {
        AppDefaults.store.removeObject(forKey: defaultsKey)
    }

    var iconSize: DesktopIconSize {
        get { DesktopIconSize(rawValue: stored.iconSize) ?? .medium }
        set { stored.iconSize = newValue.rawValue; save() }
    }

    var autoArrange: Bool {
        get { stored.autoArrange }
        set { stored.autoArrange = newValue; save() }
    }

    var alignToGrid: Bool {
        get { stored.alignToGrid }
        set { stored.alignToGrid = newValue; save() }
    }

    var showIcons: Bool {
        get { stored.showIcons }
        set { stored.showIcons = newValue; save() }
    }

    var sortKey: DesktopSortKey {
        get { DesktopSortKey(rawValue: stored.sortKey) ?? .name }
        set { stored.sortKey = newValue.rawValue; save() }
    }

    func place(for name: String) -> Place? {
        guard let value = stored.positions[name], value.count == 2 else { return nil }
        return Place(point: CGPoint(x: value[0], y: value[1]), screenID: stored.screens?[name])
    }

    /// Call `save()` after a batch of updates.
    func setPlace(_ place: Place, for name: String) {
        stored.positions[name] = [place.point.x, place.point.y]
        stored.screens = stored.screens ?? [:]
        stored.screens?[name] = place.screenID
    }

    func renamePosition(from oldName: String, to newName: String) {
        stored.positions[newName] = stored.positions.removeValue(forKey: oldName)
        let screen = stored.screens?.removeValue(forKey: oldName)
        stored.screens?[newName] = screen
        save()
    }

    /// Forgets positions of files that are gone.
    func prune(keeping names: Set<String>) {
        let before = stored.positions.count
        stored.positions = stored.positions.filter { names.contains($0.key) }
        stored.screens = stored.screens?.filter { names.contains($0.key) }
        if stored.positions.count != before { save() }
    }

    func save() {
        if let data = try? JSONEncoder().encode(stored) {
            AppDefaults.store.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Reads Finder's desktop icon positions from `~/Desktop/.DS_Store`.
///
/// The file is a B-tree of records (name, 4-char structure id, typed value). Desktop positions
/// live in `dilc` blobs (32 bytes, big-endian) describing the icon center:
///  - bytes 0…3: the monitor (0 main, 1 the next one…);
///  - bytes 4…5: anchor — 0 screen center, 1 top-right, 2 bottom-right, 3 bottom-left, 4 top-left;
///  - bytes 8…15: Int32 x, y offset in points from the anchor (y grows downwards);
///  - bytes 16…23: the same point as fractions of the screen × 100 000 (can be stale, used as a fallback).
enum FinderDesktopLayout {
    struct ViewOptions: Equatable {
        var iconSize = DesktopIconSize.medium
        var alignToGrid = true
        var autoArrange = false
        var sortKey = DesktopSortKey.name
    }

    /// Finder's desktop "Show View Options" (`com.apple.finder` → `DesktopViewSettings`):
    /// icon size in points and "Sort by" (none / snap to grid / name / kind / date / size).
    static func viewOptions(_ settings: [String: Any]?) -> ViewOptions {
        var options = ViewOptions()
        guard let icon = settings?["IconViewSettings"] as? [String: Any] else { return options }
        if let size = (icon["iconSize"] as? NSNumber)?.doubleValue {
            options.iconSize = DesktopIconSize.allCases.min { abs($0.iconSide - size) < abs($1.iconSide - size) } ?? .medium
        }
        switch icon["arrangeBy"] as? String {
        case "none": options.alignToGrid = false
        case "name": options.autoArrange = true; options.sortKey = .name
        case "kind": options.autoArrange = true; options.sortKey = .type
        case "dateModified", "dateCreated", "dateAdded", "dateLastOpened": options.autoArrange = true; options.sortKey = .date
        case "size": options.autoArrange = true; options.sortKey = .size
        default: break  // "grid", tags: kept where they are, snapped to the grid
        }
        return options
    }


    /// Icon centers as fractions of their monitor (y from the top) and the monitor's number
    /// (0 is the main one). `screenSizes` are the connected monitors in the system's order.
    static func iconPlaces(in desktop: URL, screenSizes: [CGSize]) -> [String: (screen: Int, point: CGPoint)] {
        guard let data = try? Data(contentsOf: desktop.appendingPathComponent(".DS_Store")),
              let main = screenSizes.first, main.width > 0, main.height > 0 else { return [:] }
        var result: [String: (screen: Int, point: CGPoint)] = [:]
        try? DSStore(bytes: [UInt8](data)).forEachRecord { name, structure, value in
            guard structure == "dilc", value.count >= 24 else { return }
            let screen = Int(DSStore.u32(value, 0))
            let anchor = Int(DSStore.u32(value, 4) >> 16)
            let dx = Double(Int32(bitPattern: DSStore.u32(value, 8)))
            let dy = Double(Int32(bitPattern: DSStore.u32(value, 12)))
            // Offsets are measured on the icon's own monitor; one that isn't connected: fractions only
            let size = screenSizes.indices.contains(screen) ? screenSizes[screen] : nil
            let (w, h) = (Double(size?.width ?? 0), Double(size?.height ?? 0))
            var origin: (Double, Double)? = switch anchor {
            case 0: (w / 2, h / 2)
            case 1: (w, 0)
            case 2: (w, h)
            case 3: (0, h)
            case 4: (0, 0)
            default: nil
            }
            if w <= 0 || h <= 0 { origin = nil }
            var point: CGPoint
            if let origin {
                point = CGPoint(x: (origin.0 + dx) / w, y: (origin.1 + dy) / h)
            } else {
                point = CGPoint(x: Double(Int32(bitPattern: DSStore.u32(value, 16))) / 100_000,
                                y: Double(Int32(bitPattern: DSStore.u32(value, 20))) / 100_000)
            }
            guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
            result[name] = (screen, point)
        }
        return result
    }

    struct DSStore {
        struct Malformed: Error {}
        let bytes: [UInt8]

        static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        }

        private func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else { throw Malformed() }
            return Int(Self.u32(bytes, offset))
        }

        private func slice(_ offset: Int, _ length: Int) throws -> [UInt8] {
            guard offset >= 0, length >= 0, offset + length <= bytes.count else { throw Malformed() }
            return Array(bytes[offset..<offset + length])
        }

        /// Calls `body` for blob records and `strings` for Unicode string records (name, structure id, value).
        func forEachRecord(_ body: (String, String, [UInt8]) -> Void,
                           strings: ((String, String, String) -> Void)? = nil) throws {
            // Header: 00 00 00 01 'Bud1' rootOffset rootSize …  (offsets are relative to byte 4)
            guard bytes.count > 36, try slice(4, 4) == Array("Bud1".utf8) else { throw Malformed() }
            var cursor = try u32(8) + 4
            let blockCount = try u32(cursor)
            cursor += 8
            var addresses: [Int] = []
            for i in 0..<blockCount { addresses.append(try u32(cursor + 4 * i)) }
            cursor += 4 * ((blockCount + 255) / 256 * 256)

            // Table of contents: name → block id; "DSDB" is the tree header
            var toc: [String: Int] = [:]
            let tocCount = try u32(cursor)
            cursor += 4
            for _ in 0..<tocCount {
                let length = Int(try slice(cursor, 1)[0])
                let name = String(decoding: try slice(cursor + 1, length), as: UTF8.self)
                toc[name] = try u32(cursor + 1 + length)
                cursor += 1 + length + 4
            }

            func blockOffset(_ id: Int) throws -> Int {
                guard addresses.indices.contains(id) else { throw Malformed() }
                return (addresses[id] & ~0x1f) + 4
            }

            guard let master = toc["DSDB"] else { throw Malformed() }
            let root = try u32(try blockOffset(master))

            func readRecord(_ start: Int) throws -> Int {
                var offset = start
                let nameLength = try u32(offset)
                let raw = try slice(offset + 4, nameLength * 2)
                let name = String(decoding: stride(from: 0, to: raw.count, by: 2).map {
                    UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1])
                }, as: UTF16.self)
                offset += 4 + nameLength * 2
                let structure = String(decoding: try slice(offset, 4), as: UTF8.self)
                let type = String(decoding: try slice(offset + 4, 4), as: UTF8.self)
                offset += 8
                switch type {
                case "long", "shor", "type": offset += 4
                case "bool": offset += 1
                case "comp", "dutc": offset += 8
                case "blob":
                    let length = try u32(offset)
                    body(name, structure, try slice(offset + 4, length))
                    offset += 4 + length
                case "ustr":
                    let length = try u32(offset)
                    if let strings {
                        let raw = try slice(offset + 4, length * 2)
                        strings(name, structure, String(decoding: stride(from: 0, to: raw.count, by: 2).map {
                            UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1])
                        }, as: UTF16.self))
                    }
                    offset += 4 + length * 2
                default: throw Malformed()
                }
                return offset
            }

            func readNode(_ id: Int, depth: Int) throws {
                guard depth < 32 else { throw Malformed() }
                var offset = try blockOffset(id)
                let rightmost = try u32(offset)
                let count = try u32(offset + 4)
                offset += 8
                for _ in 0..<count {
                    if rightmost != 0 {
                        try readNode(try u32(offset), depth: depth + 1)
                        offset += 4
                    }
                    offset = try readRecord(offset)
                }
                if rightmost != 0 { try readNode(rightmost, depth: depth + 1) }
            }

            try readNode(root, depth: 0)
        }
    }
}

/// Desktop icon labels the way Finder draws them: at most two lines; the first breaks after a word
/// (inside a word if one doesn't fit), the second is shortened in the middle so the end of the
/// name — the extension — stays visible: "Снимок экрана —" / "2026-0…9.44.png".
enum DesktopLabel {
    static func lines(_ text: NSAttributedString, width: CGFloat) -> [NSAttributedString] {
        guard text.length > 0, text.size().width > width else { return [text] }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var count = CTTypesetterSuggestLineBreak(typesetter, 0, Double(width))
        if count <= 0 { count = CTTypesetterSuggestClusterBreak(typesetter, 0, Double(width)) }
        count = min(max(count, 1), text.length)
        let first = trimmed(text.attributedSubstring(from: NSRange(location: 0, length: count)))
        let rest = trimmed(text.attributedSubstring(from: NSRange(location: count, length: text.length - count)))
        return rest.length > 0 ? [first, middleTruncating(rest)] : [first]
    }

    /// Drawn in a one-line rect, the text loses its middle instead of spilling over.
    private static func middleTruncating(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let paragraph = ((text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func trimmed(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        var start = 0, end = string.length
        while start < end, CharacterSet.whitespaces.contains(UnicodeScalar(string.character(at: start)) ?? " ") { start += 1 }
        while end > start, CharacterSet.whitespaces.contains(UnicodeScalar(string.character(at: end - 1)) ?? " ") { end -= 1 }
        return text.attributedSubstring(from: NSRange(location: start, length: end - start))
    }
}
