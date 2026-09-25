import AppKit

/// Where WinEx keeps its settings. Debug scenarios get their own, emptied store, so a test run
/// can never change the user's settings (or switch Finder replacement on).
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if Scenario.isRequested, let scenarioStore = UserDefaults(suiteName: "dev.winex.WinEx.scenario") {
            scenarioStore.removePersistentDomain(forName: "dev.winex.WinEx.scenario")
            return scenarioStore
        }
        #endif
        return .standard
    }()
}

enum Settings {
    private static var defaults: UserDefaults { AppDefaults.store }

    static var replaceFinder: Bool {
        get { defaults.bool(forKey: "replaceFinder") }
        set { defaults.set(newValue, forKey: "replaceFinder") }
    }

    /// Settings ▸ Теги: folders take the colour of their first coloured tag, as in macOS 26 Finder.
    static var tintFoldersByTags: Bool {
        get { defaults.object(forKey: "tintFoldersByTags") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "tintFoldersByTags") }
    }

    /// Windows keys: Return opens, F2 renames, Backspace goes up. Off (default): Finder keys —
    /// Return renames, ⌘↓ / ⌘O open, ⌘↑ goes up.
    static var windowsKeys: Bool {
        get { defaults.bool(forKey: "windowsKeys") }
        set { defaults.set(newValue, forKey: "windowsKeys") }
    }

    static var showHidden: Bool {
        get { defaults.bool(forKey: "showHidden") }
        set { defaults.set(newValue, forKey: "showHidden") }
    }

    /// Where new windows open: "home", "desktop", "downloads", "documents", "computer" or a folder path.
    static var startFolder: String {
        get { defaults.string(forKey: "startFolder") ?? "home" }
        set { defaults.set(newValue, forKey: "startFolder") }
    }

    /// The place `startFolder` stands for (a missing custom folder falls back to the home folder).
    static var startURL: URL {
        let fm = FileManager.default
        func standard(_ directory: FileManager.SearchPathDirectory) -> URL {
            fm.urls(for: directory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        }
        switch startFolder {
        case "home": return fm.homeDirectoryForCurrentUser
        case "desktop": return standard(.desktopDirectory)
        case "downloads": return standard(.downloadsDirectory)
        case "documents": return standard(.documentDirectory)
        case "computer": return Places.computerURL
        case let path:
            var isFolder: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
                ? URL(fileURLWithPath: path) : fm.homeDirectoryForCurrentUser
        }
    }

    /// Search the whole Mac instead of the current folder.
    static var searchWholeMac: Bool {
        get { defaults.bool(forKey: "searchWholeMac") }
        set { defaults.set(newValue, forKey: "searchWholeMac") }
    }

    /// Search inside files too (on by default, like Finder), not only names.
    static var searchContents: Bool {
        get { defaults.object(forKey: "searchContents") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "searchContents") }
    }
}

extension Notification.Name {
    static let showHiddenChanged = Notification.Name("WinExShowHiddenChanged")
    static let keyboardSettingsChanged = Notification.Name("WinExKeyboardSettingsChanged")
}

extension URL {
    /// A directory we can browse into (app bundles and other packages are opened instead).
    var isBrowsableDirectory: Bool {
        let values = try? resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
    }

    var displayName: String {
        FileManager.default.displayName(atPath: path)
    }
}

/// One entry of a directory listing.
final class FileItem {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey,
        .localizedTypeDescriptionKey, .fileSizeKey, .localizedNameKey, .tagNamesKey,
    ]

    let url: URL
    let name: String
    let isFolder: Bool
    let modified: Date?
    let typeDescription: String
    let size: Int?
    let tagNames: [String]

    /// A non-file item (a network server): fixed name and icon, opened by URL.
    init(virtual name: String, url: URL, icon: NSImage, kind: String) {
        self.url = url
        self.name = name
        isFolder = true
        modified = nil
        typeDescription = kind
        size = nil
        tagNames = []
        self.icon = icon
    }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: Set(Self.keys))
        let isDirectory = values?.isDirectory ?? false
        isFolder = isDirectory && !(values?.isPackage ?? false)
        // Localized names for folders ("Загрузки"), real names for files so extensions stay visible
        name = isFolder ? (values?.localizedName ?? url.lastPathComponent) : url.lastPathComponent
        modified = values?.contentModificationDate
        typeDescription = values?.localizedTypeDescription ?? ""
        size = isDirectory ? nil : values?.fileSize
        tagNames = values?.tagNames ?? []
    }

    /// Finder tags with their colors (read lazily: only views that show tags ask).
    lazy var tags: [FileTags.Tag] = tagNames.isEmpty ? [] : FileTags.tags(of: url)

    var tagColors: [NSColor] { tags.compactMap { FileTags.color(forIndex: $0.color) } }

    /// File icon; customized folders (tag color, symbol / emoji) are drawn like macOS 26 Finder does.
    lazy var icon: NSImage = {
        let tint = Settings.tintFoldersByTags ? tags.lazy.compactMap({ FileTags.color(forIndex: $0.color) }).first : nil
        if isFolder, let custom = FolderIcon.custom(tagColor: tint,
                                                    customization: FolderCustomization.read(url)) {
            return custom
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }()

    var sizeDescription: String? {
        size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    /// A column to sort by ("name", "date", "type", "size") and a direction.
    struct SortOrder: Equatable, Sendable {
        var key: String
        var ascending: Bool
    }

    /// Folders first, like in Explorer; ties are broken by name.
    static func sort(_ items: inout [FileItem], by order: SortOrder) {
        func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
        items.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let result: ComparisonResult
            switch order.key {
            case "date": result = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case "type": result = a.typeDescription.localizedStandardCompare(b.typeDescription)
            case "size": result = compare(a.size ?? -1, b.size ?? -1)
            case "folder": result = a.url.deletingLastPathComponent().path.localizedStandardCompare(b.url.deletingLastPathComponent().path)
            default: result = a.name.localizedStandardCompare(b.name)
            }
            if result == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    static func sorted(_ items: [FileItem], by order: SortOrder) -> [FileItem] {
        var items = items
        sort(&items, by: order)
        return items
    }
}

/// Block-based notification observers owned by one object: all removed by `removeAll()` or when
/// the owner (and so this bag) goes away. Blocks run on the main thread.
final class Observers: @unchecked Sendable {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func add(_ name: Notification.Name, center: NotificationCenter = .default, object: Any? = nil,
             _ block: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { block() }
        }
        tokens.append((center, token))
    }

    func removeAll() {
        tokens.forEach { $0.center.removeObserver($0.token) }
        tokens = []
    }

    deinit { removeAll() }
}

/// Calls `onChange` when the contents of a directory change. Events are coalesced: the first one
/// schedules a call `delay` later and everything arriving meanwhile rides along with it, so a
/// burst (a copy of thousands of files) costs a few reloads, not thousands.
@MainActor
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var scheduled = false

    init?(url: URL, delay: TimeInterval = 0.15, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.scheduled else { return }
                self.scheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.scheduled = false
                        onChange()
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

enum FileOps {
    /// "name.ext" → "name - копия.ext", "name - копия (2).ext", … until the name is free.
    static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        repeat {
            let suffix = n == 1 ? " - копия" : " - копия (\(n))"
            candidate = directory.appendingPathComponent(base + suffix + (ext.isEmpty ? "" : "." + ext))
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    /// "Новая папка", "Новая папка (2)", … (extension kept: "Новый текстовый документ (2).txt").
    static func newItemURL(named name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : "." + ext))
            n += 1
        }
        return candidate
    }

    static func newFolderURL(in directory: URL) -> URL {
        newItemURL(named: "Новая папка", in: directory)
    }

    /// Moves or copies files into `directory` in the background, with Explorer's progress window
    /// and "Replace or skip" dialog. Moves into the folder the files already live in are skipped;
    /// copies there get "- копия" names.
    @MainActor
    static func transfer(_ urls: [URL], to directory: URL, copy: Bool) {
        FileOperations.start(copy ? .copy : .move, urls, to: directory)
    }

    /// Range to preselect when renaming: the name without its extension, like Explorer.
    static func baseNameRange(of name: String, isFolder: Bool) -> NSRange {
        let ns = name as NSString
        let ext = ns.pathExtension
        guard !isFolder, !ext.isEmpty else { return NSRange(location: 0, length: ns.length) }
        return NSRange(location: 0, length: ns.length - (ext as NSString).length - 1)
    }

    static func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @MainActor
    static func trash(_ urls: [URL]) {
        // Files may already be gone (e.g. the Dock trashed them after a drag)
        FileOperations.start(.trash, urls)
    }
}

/// Russian plural: plural(5, "элемент", "элемента", "элементов") → "элементов"
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod10 = n % 10, mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return one }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
    return many
}

func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

/// Plain view filled with a (dynamic) color. Uses its own layer: drawing with `NSRect.fill()`
/// (copy compositing) wipes sibling views when AppKit draws several views into one layer.
final class ColorView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}

/// Finder / Explorer "slow click": clicking the name of an item that was already the only one
/// selected starts renaming, once the double-click interval has passed without a second click.
@MainActor
final class SlowClickRename {
    private var pending: DispatchWorkItem?

    /// Call on every mouse down / key down: a double-click, a drag or typing cancels the rename.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    func schedule(_ rename: @escaping @MainActor () -> Void) {
        cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                rename()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// A plain single click: no modifiers, no second click.
    static func isPlainClick(_ event: NSEvent) -> Bool {
        event.clickCount == 1 && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
    }
}
