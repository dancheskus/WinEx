import AppKit

/// A folder's layout as Finder stores it in `.DS_Store` — read for folders styled to be seen in
/// Finder (a disk image's window: its background picture, the icons' size and places).
///
/// The file is a "buddy allocator" store: blocks found through an address table, one of them the
/// root of a B-tree of records (file name, a four-letter code, a typed value).
struct DSStore {
    /// Records by file name, then code ("Iloc", "icvp", "bwsp"…).
    private(set) var records: [String: [String: Value]] = [:]

    enum Value {
        case long(UInt32), short(UInt16), bool(Bool), type(String), string(String), blob(Data), other
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 36, Self.u32(bytes, 0) == 1, Self.u32(bytes, 4) == 0x42756431 else { return nil }   // "Bud1"
        // (Offsets count from byte 4)
        let rootOffset = Int(Self.u32(bytes, 8))
        var p = rootOffset + 4
        guard p + 8 <= bytes.count else { return nil }
        let blockCount = Int(Self.u32(bytes, p)); p += 8
        var addresses: [UInt32] = []
        for i in 0..<blockCount {
            guard p + 4 * (i + 1) <= bytes.count else { return nil }
            addresses.append(Self.u32(bytes, p + 4 * i))
        }
        p += 4 * ((blockCount + 255) / 256 * 256)
        guard p + 4 <= bytes.count else { return nil }
        let directoryCount = Int(Self.u32(bytes, p)); p += 4
        var dsdb: Int?
        for _ in 0..<directoryCount {
            guard p < bytes.count else { return nil }
            let length = Int(bytes[p]); p += 1
            guard p + length + 4 <= bytes.count else { return nil }
            let name = String(bytes: bytes[p..<p + length], encoding: .ascii); p += length
            let block = Int(Self.u32(bytes, p)); p += 4
            if name == "DSDB" { dsdb = block }
        }
        func blockOffset(_ index: Int) -> Int? {
            guard addresses.indices.contains(index) else { return nil }
            return Int(addresses[index] & ~0x1f) + 4
        }
        guard let dsdb, let header = blockOffset(dsdb), header + 8 <= bytes.count else { return nil }
        let root = Int(Self.u32(bytes, header))
        var visited = Set<Int>()
        func readNode(_ block: Int) {
            guard visited.insert(block).inserted, let start = blockOffset(block), start + 8 <= bytes.count else { return }
            var q = start
            let next = Int(Self.u32(bytes, q)); q += 4
            let count = Int(Self.u32(bytes, q)); q += 4
            for _ in 0..<count {
                if next != 0 {
                    guard q + 4 <= bytes.count else { return }
                    readNode(Int(Self.u32(bytes, q))); q += 4
                }
                guard let (name, code, value, end) = Self.record(bytes, q) else { return }
                records[name, default: [:]][code] = value
                q = end
            }
            if next != 0 { readNode(next) }
        }
        readNode(root)
    }

    init?(folder: URL) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".DS_Store")) else { return nil }
        self.init(data: data)
    }

    // MARK: What a window needs

    /// Where Finder puts an icon: its centre, in points from the window's top-left.
    func iconCenter(of name: String) -> CGPoint? {
        guard case .blob(let data)? = records[name]?["Iloc"], data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        return CGPoint(x: CGFloat(Self.u32(bytes, 0)), y: CGFloat(Self.u32(bytes, 4)))
    }

    /// The folder's icon view settings (a property list: background, icon size…).
    var iconViewOptions: [String: Any]? {
        guard case .blob(let data)? = records["."]?["icvp"] else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// The window's size (Finder's «WindowBounds»), if stored.
    var windowSize: CGSize? {
        guard case .blob(let data)? = records["."]?["bwsp"],
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bounds = plist["WindowBounds"] as? String else { return nil }
        let rect = NSRectFromString(bounds)
        return rect.width > 0 ? rect.size : nil
    }

    // MARK: Reading

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func record(_ b: [UInt8], _ start: Int) -> (String, String, Value, Int)? {
        var p = start
        guard p + 4 <= b.count else { return nil }
        let length = Int(u32(b, p)); p += 4
        guard p + length * 2 + 8 <= b.count else { return nil }
        let name = String(data: Data(b[p..<p + length * 2]), encoding: .utf16BigEndian) ?? ""
        p += length * 2
        let code = String(bytes: b[p..<p + 4], encoding: .ascii) ?? ""; p += 4
        let type = String(bytes: b[p..<p + 4], encoding: .ascii) ?? ""; p += 4
        let value: Value
        switch type {
        case "long": value = .long(u32(b, p)); p += 4
        case "shor": value = .short(UInt16(truncatingIfNeeded: u32(b, p))); p += 4
        case "bool": guard p < b.count else { return nil }; value = .bool(b[p] != 0); p += 1
        case "type": value = .type(String(bytes: b[p..<min(p + 4, b.count)], encoding: .ascii) ?? ""); p += 4
        case "comp", "dutc": value = .other; p += 8
        case "blob":
            let size = Int(u32(b, p)); p += 4
            guard p + size <= b.count else { return nil }
            value = .blob(Data(b[p..<p + size])); p += size
        case "ustr":
            let count = Int(u32(b, p)); p += 4
            guard p + count * 2 <= b.count else { return nil }
            value = .string(String(data: Data(b[p..<p + count * 2]), encoding: .utf16BigEndian) ?? ""); p += count * 2
        default: return nil
        }
        return (name, code, value, p)
    }
}

/// A folder Finder shows styled (a disk image's window): its background, the icons' size, where
/// each icon goes and a text colour that reads on the background. Nil for ordinary folders (no
/// background of their own) — those keep WinEx's own grid.
struct FinderLook {
    var background: NSImage?
    var color: NSColor?
    var iconSize: CGFloat
    var positions: [String: CGPoint]
    var textColor: NSColor

    static func read(_ folder: URL) -> FinderLook? {
        guard let store = DSStore(folder: folder), let dot = store.records["."] else { return nil }
        let options = store.iconViewOptions
        var picture: Data?, color: NSColor?
        // Newer Finder: the icon view options' property list
        if let options, let kind = options["backgroundType"] as? Int {
            if kind == 2 { picture = options["backgroundImageAlias"] as? Data }
            if kind == 1, let r = options["backgroundColorRed"] as? Double, let g = options["backgroundColorGreen"] as? Double,
               let b = options["backgroundColorBlue"] as? Double {
                color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
        }
        // Older Finder: "BKGD" (picture or colour) and "pict" (the picture's alias)
        if picture == nil, color == nil, case .blob(let data)? = dot["BKGD"], data.count >= 10 {
            let bytes = [UInt8](data), kind = String(bytes: bytes[0..<4], encoding: .ascii)
            if kind == "PctB", case .blob(let alias)? = dot["pict"] { picture = alias }
            if kind == "ClrB" {
                func channel(_ i: Int) -> CGFloat { CGFloat(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])) / 65535 }
                color = NSColor(srgbRed: channel(4), green: channel(6), blue: channel(8), alpha: 1)
            }
        }
        let background = picture.flatMap { resolveAlias($0) }.flatMap(NSImage.init(contentsOf:)) ?? (picture != nil ? hiddenBackground(in: folder) : nil)
        guard background != nil || color != nil else { return nil }
        var iconSize: CGFloat = 64
        if let size = options?["iconSize"] as? Double { iconSize = size }
        else if case .blob(let data)? = dot["icvo"], data.count >= 6, String(bytes: data.prefix(4), encoding: .ascii) == "icv4" {
            iconSize = CGFloat(UInt16(data[data.startIndex + 4]) << 8 | UInt16(data[data.startIndex + 5]))
        }
        var positions: [String: CGPoint] = [:]
        for name in store.records.keys where name != "." { if let point = store.iconCenter(of: name) { positions[name] = point } }
        let light = (background.map(averageLuminance) ?? color.map(luminance) ?? 0) > 0.6
        return FinderLook(background: background, color: color, iconSize: min(max(iconSize, 16), 256), positions: positions,
                          textColor: light ? .black : .white)
    }

    /// A classic alias record (as Finder stores the background picture) → the file.
    private static func resolveAlias(_ data: Data) -> URL? {
        guard let bookmark = CFURLCreateBookmarkDataFromAliasRecord(nil, data as CFData)?.takeRetainedValue() as Data? else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Where disk images keep the picture: ".background.png" or a ".background" folder.
    private static func hiddenBackground(in folder: URL) -> NSImage? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0.lowercased().hasPrefix(".background") }.sorted() ?? []
        for name in names {
            let url = folder.appendingPathComponent(name)
            if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let inside = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
                if let image = inside.lazy.compactMap({ NSImage(contentsOf: url.appendingPathComponent($0)) }).first { return image }
            } else if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }

    private static func averageLuminance(_ image: NSImage) -> CGFloat {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 0, y: 0).map(luminance) ?? 0
    }
}

/// A Finder-styled folder's background, under its icons: the colour, the picture at its own size
/// from the top-left corner (as Finder draws it).
final class FinderLookBackground: NSView {
    var look: FinderLook? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let look else { return }
        (look.color ?? .white).setFill()
        bounds.fill()
        if let image = look.background {
            image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// Icons where Finder put them (their centres from `.DS_Store`); any others in rows below.
final class FinderLookLayout: NSCollectionViewLayout {
    var look: FinderLook?
    var names: [String] = []
    var itemSize = NSSize(width: 140, height: 190)
    var iconTop: CGFloat = 10
    private var frames: [NSRect] = []

    override func prepare() {
        super.prepare()
        guard let look else { frames = []; return }
        var placed: [NSRect] = []
        var loose: [Int] = []
        frames = names.indices.map { i in
            guard let center = look.positions[names[i]] else { loose.append(i); return .zero }
            let frame = NSRect(x: center.x - itemSize.width / 2, y: center.y - iconTop - look.iconSize / 2, width: itemSize.width, height: itemSize.height)
            placed.append(frame)
            return frame
        }
        // Items Finder has no place for: in rows under the placed ones
        let width = max(collectionView?.bounds.width ?? 600, itemSize.width)
        var x: CGFloat = 8, y = (placed.map(\.maxY).max() ?? 0) + 8
        for i in loose {
            if x + itemSize.width > width { x = 8; y += itemSize.height }
            frames[i] = NSRect(x: x, y: y, width: itemSize.width, height: itemSize.height)
            x += itemSize.width
        }
    }

    override var collectionViewContentSize: NSSize {
        let visible = collectionView?.enclosingScrollView?.contentSize ?? .zero
        let used = frames.reduce(NSRect.zero) { $0.union($1) }
        let picture = look?.background?.size ?? .zero
        return NSSize(width: max(visible.width, used.maxX + 8, picture.width), height: max(visible.height, used.maxY + 8, picture.height))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        frames.indices.filter { frames[$0].intersects(rect) }.compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard frames.indices.contains(indexPath.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frames[indexPath.item]
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}
