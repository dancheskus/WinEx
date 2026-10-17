import AppKit

/// Where WinEx keeps its settings. Debug scenarios get their own, emptied store, so a test run
/// can never change the user's settings (or switch Finder replacement on).
enum AppDefaults {
    /// The name of the store's domain (the scenario runs have their own).
    static var domainName: String {
        #if DEBUG
        if Scenario.isRequested { return "dev.winex.WinEx.scenario" }
        #endif
        return Bundle.main.bundleIdentifier ?? "dev.winex.WinEx"
    }

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

    /// "Открыть в терминале" in the context menus (off until switched on in Settings).
    static var terminalInMenu: Bool {
        get { defaults.bool(forKey: "terminalInMenu") }
        set { defaults.set(newValue, forKey: "terminalInMenu") }
    }

    /// The terminal app's path (nil: Terminal).
    static var terminalApp: String? {
        get { defaults.string(forKey: "terminalApp") }
        set { defaults.set(newValue, forKey: "terminalApp") }
    }

    /// Explorer's command bar under the address row.
    static var showCommandBar: Bool {
        get { defaults.object(forKey: "showCommandBar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showCommandBar") }
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

    /// Finder's «Показывать все расширения имён файлов»: on (the default), every name shows its
    /// extension; off, a file whose extension was hidden (Свойства ▸ Скрыть расширение, or saved so)
    /// shows its name without it.
    static var showAllExtensions: Bool {
        get { defaults.object(forKey: "showAllExtensions") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "showAllExtensions")
            NotificationCenter.default.post(name: .extensionsShownChanged, object: nil)
        }
    }

    /// Finder's «Показывать сведения об объекте» for folder windows in icon views (on by default).
    static var showItemInfo: Bool {
        get { defaults.object(forKey: "showItemInfo") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "showItemInfo")
            NotificationCenter.default.post(name: .itemInfoChanged, object: nil)
        }
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
    /// WinEx started or stopped drawing the desktop.
    static let replaceFinderChanged = Notification.Name("WinExReplaceFinderChanged")
    static let showHiddenChanged = Notification.Name("WinExShowHiddenChanged")
    static let extensionsShownChanged = Notification.Name("WinExExtensionsShownChanged")
    static let foldersOnTopChanged = Notification.Name("WinExFoldersOnTopChanged")
    static let itemInfoChanged = Notification.Name("WinExItemInfoChanged")
    static let keyboardSettingsChanged = Notification.Name("WinExKeyboardSettingsChanged")
    static let commandBarSettingChanged = Notification.Name("WinExCommandBarSettingChanged")
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
        .creationDateKey, .addedToDirectoryDateKey, .isAliasFileKey, .isSymbolicLinkKey, .hasHiddenExtensionKey,
    ]

    let url: URL
    let name: String
    let isFolder: Bool
    let modified: Date?
    let created: Date?
    /// When it was put into its folder (Finder's "Дата добавления").
    let added: Date?
    let typeDescription: String
    let size: Int?
    let tagNames: [String]
    /// An alias (Finder's, not a symlink): what it points to — its icon or preview is shown, with
    /// the alias arrow. Nil for other files and for a broken alias.
    let aliasTarget: URL?
    /// Shown without its extension (see `Settings.showAllExtensions`).
    let hidesExtension: Bool
    /// In iCloud only, not on this Mac (Finder's cloud next to the name): opening downloads it.
    let isCloudOnly: Bool

    /// A non-file item (a network server): fixed name and icon, opened by URL.
    init(virtual name: String, url: URL, icon: NSImage, kind: String) {
        self.url = url
        self.name = name
        isFolder = true
        modified = nil
        created = nil
        added = nil
        typeDescription = kind
        size = nil
        tagNames = []
        aliasTarget = nil
        hidesExtension = false
        isCloudOnly = false
        self.icon = icon
    }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: Set(Self.keys))
        let isDirectory = values?.isDirectory ?? false
        isFolder = isDirectory && !(values?.isPackage ?? false)
        // Localized names for folders ("Загрузки"), real names for files so extensions stay visible
        // (unless the file's extension is hidden and not every extension is to be shown)
        hidesExtension = !isFolder && !url.pathExtension.isEmpty && values?.hasHiddenExtension == true && !Settings.showAllExtensions
        name = isFolder ? (values?.localizedName ?? url.lastPathComponent)
            : hidesExtension ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        modified = values?.contentModificationDate
        created = values?.creationDate
        added = values?.addedToDirectoryDate
        typeDescription = values?.localizedTypeDescription ?? ""
        size = isDirectory ? nil : values?.fileSize
        tagNames = values?.tagNames ?? []
        aliasTarget = values?.isAliasFile == true && values?.isSymbolicLink != true ? try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) : nil
        // (Asked only in iCloud's folders. A folder always says it's downloaded: no cloud on folders)
        isCloudOnly = !isFolder && url.path.hasPrefix(CloudDrive.mobileDocumentsPath)
            && (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// Finder tags with their colors (read lazily: only views that show tags ask).
    lazy var tags: [FileTags.Tag] = tagNames.isEmpty ? [] : FileTags.tags(of: url)

    /// When it was last opened, as Spotlight keeps it (Finder's «Дата последнего открытия»; nil
    /// where Spotlight doesn't index, as on most servers). Read only when shown or sorted by.
    lazy var lastOpened: Date? = MDItemCreateWithURL(nil, url as CFURL)
        .flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }

    var tagColors: [NSColor] { tags.compactMap { FileTags.color(forIndex: $0.color) } }

    /// File icon; customized folders (tag color, symbol / emoji) are drawn like macOS 26 Finder does.
    /// Made on first use — it reads the disk, slow on a server (see `hasIcon`, `makeIcon`).
    var icon: NSImage {
        get {
            if let iconStorage { return iconStorage }
            let made = Self.makeIcon(url: url, isFolder: isFolder, aliasTarget: aliasTarget, tags: tags)
            iconStorage = made
            return made
        }
        set { iconStorage = newValue }
    }
    private var iconStorage: NSImage?
    var hasIcon: Bool { iconStorage != nil }

    /// The icon, made from what it depends on (any thread).
    static func makeIcon(url: URL, isFolder: Bool, aliasTarget: URL?, tags: [FileTags.Tag]) -> NSImage {
        // An alias: what it points to (a folder with its look, an app, the file's type), with the arrow
        if let aliasTarget { return AliasIcon.badged(FileItem(url: aliasTarget).icon) }
        // The last tag put on it (with a color) colors it, as in Finder
        let tint = Settings.tintFoldersByTags ? tags.last(where: { FileTags.color(forIndex: $0.color) != nil })?.color : nil
        // An app's folder in iCloud Drive (Pages, Просмотр): the system's folder with the app on it
        if isFolder, let appFolder = CloudDrive.appFolderIcon(url) { return appFolder }
        if isFolder, let custom = FolderIcon.icon(for: url, tagColor: tint, customization: FolderCustomization.read(url)) {
            return custom
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var sizeDescription: String? {
        size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    /// A column to sort by ("name", "date", "created", "added", "type", "size") and a direction.
    struct SortOrder: Equatable, Sendable {
        var key: String
        var ascending: Bool
        /// Folders before files, like Explorer; off (the default), they're sorted in among the
        /// files, like Finder (a film, then its folder of the same name). Each folder's own.
        var foldersOnTop = false
    }

    /// Folders first, like in Explorer, if the order says so; ties are broken by name.
    static func sort(_ items: inout [FileItem], by order: SortOrder) {
        func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
        let foldersOnTop = order.foldersOnTop
        items.sort { a, b in
            if foldersOnTop, a.isFolder != b.isFolder { return a.isFolder }
            let result: ComparisonResult
            switch order.key {
            case "date": result = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case "created": result = compare(a.created ?? .distantPast, b.created ?? .distantPast)
            case "added": result = compare(a.added ?? .distantPast, b.added ?? .distantPast)
            case "opened": result = compare(a.lastOpened ?? .distantPast, b.lastOpened ?? .distantPast)
            case "tags":
                // By the first tag's name; untagged items after the tagged ones (A to Z)
                switch (a.tags.first?.name, b.tags.first?.name) {
                case let (x?, y?): result = x.localizedStandardCompare(y)
                case (.some, nil): result = .orderedAscending
                case (nil, .some): result = .orderedDescending
                case (nil, nil): result = .orderedSame
                }
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
            let suffix = n == 1 ? L(" - копия") : L(" - копия (%@)", n)
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
        newItemURL(named: L("Новая папка"), in: directory)
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

    /// The new name typed for `url`: a file shown without its (hidden) extension keeps it — the name
    /// typed gets it back unless it ends with it already.
    static func fullName(_ typed: String, renaming url: URL) -> String {
        let ext = url.pathExtension
        guard !ext.isEmpty, !Settings.showAllExtensions,
              (try? url.resourceValues(forKeys: [.hasHiddenExtensionKey]))?.hasHiddenExtension == true,
              !typed.lowercased().hasSuffix("." + ext.lowercased()) else { return typed }
        return typed + "." + ext
    }

    static func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    #if DEBUG
    /// Scenario runs: what would go to the Trash, instead of trashing it.
    nonisolated(unsafe) static var debugTrashed: (([URL]) -> Void)?
    #endif

    @MainActor
    static func trash(_ urls: [URL]) {
        #if DEBUG
        if let debugTrashed { return debugTrashed(urls) }
        #endif
        // Files may already be gone (e.g. the Dock trashed them after a drag)
        // A volume without a Trash (a NAS share, some USB disks): like Finder, those are deleted
        // right away — after saying so
        let (trashable, noTrash) = urls.reduce(into: ([URL](), [URL]())) { result, url in
            if hasTrash(for: url) { result.0.append(url) } else { result.1.append(url) }
        }
        if !trashable.isEmpty { FileOperations.start(.trash, trashable) }
        guard !noTrash.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = noTrash.count == 1
            ? L("«%@» будет удалён сразу.", noTrash[0].lastPathComponent)
            : L("%@ объектов будут удалены сразу.", noTrash.count)
        alert.informativeText = L("На этом диске нет Корзины. Это действие нельзя отменить.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Удалить"))
        alert.addButton(withTitle: L("Отменить"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FileOperations.start(.delete, noTrash)
    }

    /// Whether the volume of `url` has a Trash to move it into.
    private static func hasTrash(for url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }   // (gone: nothing to ask about)
        // A local disk gets its Trash when something is first put in it; a network share has one only if it says so
        if (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal != false { return true }
        return (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)) != nil
    }
}

/// Finder's alias look: the original's icon (or preview) with the small curved arrow at its
/// bottom-left corner — macOS's own badge.
enum AliasIcon {
    private static let badge = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AliasBadgeIcon.icns")

    static func badged(_ image: NSImage) -> NSImage {
        guard let badge else { return image }
        let side = max(image.size.width, image.size.height, 32)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: DesktopView.aspectFit(image.size, in: rect))
            badge.draw(in: rect)
            return true
        }
    }

    /// Previews go to the original (an alias has none of its own).
    static func previewSource(_ item: FileItem) -> URL { item.aliasTarget ?? item.url }

    /// The original is a folder or an app: its icon is the picture (no preview).
    static func isContainer(_ item: FileItem) -> Bool {
        guard let target = item.aliasTarget else { return false }
        return target.hasDirectoryPath || (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

/// A file name for a menu item: a long one loses its middle (the start and the extension stay), so
/// the menu keeps its width — «Инструкция_Пасса…кумента.docx».
func menuName(_ name: String, limit: Int = 30) -> String {
    guard name.count > limit else { return name }
    let tail = max(8, limit / 3)
    return String(name.prefix(limit - tail - 1)) + "…" + String(name.suffix(tail))
}

/// Russian plural: plural(5, "элемент", "элемента", "элементов") → "элементов"
/// Russian forms for 1, 2–4 and 5+ ("файл", "файла", "файлов"); in English the singular for 1,
/// the plural otherwise (the translations of `one` and `many`).
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    if Localization.isEnglish { return n == 1 ? L(one) : L(many) }
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

/// Tags (and other extended attributes / Finder info) changed on items right inside a folder — by
/// Finder or any other app. The folder itself doesn't change then, so `DirectoryWatcher` doesn't
/// hear it; FSEvents with file-level events does. `onChange` runs on the main thread, at most a few
/// times a second.
final class TagChangeWatcher {
    private var stream: FSEventStreamRef?
    private let folder: String
    private let onChange: () -> Void
    private var pending = false

    init?(url: URL, onChange: @escaping () -> Void) {
        folder = Self.plain(url.resolvingSymlinksInPath().standardizedFileURL.path)
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<TagChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let interesting = FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemFinderInfoMod)
            for n in 0..<min(count, list.count) where flags[n] & interesting != 0 {
                if TagChangeWatcher.plain((list[n] as NSString).deletingLastPathComponent) == watcher.folder { watcher.changed(); return }
            }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    /// FSEvents reports real paths (/private/var/…, /private/tmp/…); URLs drop the "/private".
    private static func plain(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.pending = false
            self?.onChange()
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
