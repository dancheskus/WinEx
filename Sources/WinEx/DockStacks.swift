import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing
import os

/// A folder in the Dock as WinEx's stack: the Dock's own folder stacks only open Finder, so WinEx
/// puts a small app of its own there instead (Contents/Helpers/WinExStack, one bundle per folder,
/// WinEx's icon with the folder's on it). A click on it shows the folder above the tile — a fan, a
/// grid or a list, as the Dock does — drawn by WinEx; files dropped on it go into the folder.
struct DockStack: Codable, Equatable {
    var id: String
    var path: String
    var bookmark: Data?
    var view: View = .automatic
    var sort: Sort = .name
    /// The Dock's own stack of this folder that WinEx's took the place of (its tile, as the Dock
    /// keeps it): put back when WinEx's is taken away.
    var finderTile: Data?
    /// The tile's picture, as the Dock's «Показывать как»: the first items stacked, or the folder
    /// with the first item peeking out of it.
    var display: Display?

    enum Display: String, Codable { case stack, folder }

    enum View: String, Codable, CaseIterable { case automatic, fan, grid, list }
    enum Sort: String, Codable, CaseIterable { case name, added, modified, created, kind }

    var folder: URL { URL(fileURLWithPath: path) }

    /// How the items are ordered: the first is nearest the Dock (a fan's bottom, a grid's start).
    var sortOrder: FileItem.SortOrder {
        switch sort {
        case .name: return .init(key: "name", ascending: true)
        case .added: return .init(key: "added", ascending: false)
        case .modified: return .init(key: "date", ascending: false)
        case .created: return .init(key: "created", ascending: false)
        case .kind: return .init(key: "type", ascending: true)
        }
    }

    static func title(_ view: View) -> String {
        switch view {
        case .automatic: return L("Автоматически")
        case .fan: return L("Веером")
        case .grid: return L("Сеткой")
        case .list: return L("Списком")
        }
    }

    static func title(_ sort: Sort) -> String {
        switch sort {
        case .name: return L("Имени")
        case .added: return L("Дате добавления")
        case .modified: return L("Дате изменения")
        case .created: return L("Дате создания")
        case .kind: return L("Типу")
        }
    }
}

@MainActor
enum DockStacks {
    nonisolated static let log = Logger(subsystem: "dev.winex.WinEx", category: "dockStacks")
    /// Posted when a stack is added, removed or changed.
    static let changed = Notification.Name("WinExDockStacksChanged")
    /// What a stack's app sends WinEx (see Sources/WinExStack).
    nonisolated static let request = Notification.Name("dev.winex.WinEx.stack")

    // MARK: Stored

    static var all: [DockStack] {
        get {
            guard let data = AppDefaults.store.data(forKey: "dockStacks") else { return [] }
            return (try? JSONDecoder().decode([DockStack].self, from: data)) ?? []
        }
        set {
            AppDefaults.store.set(try? JSONEncoder().encode(newValue), forKey: "dockStacks")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func stack(id: String) -> DockStack? { all.first { $0.id == id } }

    static func stack(for folder: URL) -> DockStack? {
        let path = folder.standardizedFileURL.path
        return all.first { $0.folder.standardizedFileURL.path == path }
    }

    static func update(_ stack: DockStack) {
        var stacks = all
        guard let i = stacks.firstIndex(where: { $0.id == stack.id }) else { return }
        stacks[i] = stack
        all = stacks
    }

    /// The stack's folder now: followed by its bookmark when it was moved or renamed (and the
    /// path stored again).
    static func folder(of stack: DockStack) -> URL? {
        if FileManager.default.fileExists(atPath: stack.path) { return stack.folder }
        var stale = false
        guard let bookmark = stack.bookmark,
              let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        var moved = stack
        moved.path = url.path
        moved.bookmark = (try? url.bookmarkData()) ?? bookmark
        update(moved)
        return url
    }

    // MARK: Adding and taking away

    /// Puts `folder` in the Dock as WinEx's stack: in place of the Dock's own stack of it when
    /// there is one, otherwise at the end of the Dock's right side. The Dock restarts to show it.
    static func add(_ folder: URL) throws {
        if let existing = stack(for: folder) {
            // Already WinEx's: back in the Dock if it was taken out by hand
            try makeBundle(for: existing)
            if !isInDock(existing) { putInDock(existing) }
            return
        }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        var stack = DockStack(id: id, path: folder.standardizedFileURL.path, bookmark: try? folder.bookmarkData())
        // The Downloads stack is newest first, as the Dock's is
        if folder.standardizedFileURL.path == FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.standardizedFileURL.path {
            stack.sort = .added
        }
        try makeBundle(for: stack)
        all += [stack]
        putInDock(stack)
        launchInBackground(stack)
        self.stack(id: stack.id).map(refreshIcon)
    }

    /// Takes the stack out of the Dock (the Dock's own stack of the folder back where it was, if
    /// WinEx's took its place), quits its app and deletes it.
    static func remove(_ stack: DockStack) {
        let app = bundleURL(for: stack)
        if let app {
            let finderTile = stack.finderTile.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            editDock { removing(app, restoring: finderTile, from: $0) }
        }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(for: stack)) { running.terminate() }
        try? FileManager.default.removeItem(at: bundlesRoot.appendingPathComponent(stack.id))
        all = all.filter { $0.id != stack.id }
    }

    static func isInDock(_ stack: DockStack) -> Bool {
        guard let app = bundleURL(for: stack) else { return false }
        return index(of: app, in: dockOthers()) != nil
    }

    /// Folders the Dock shows as its own stacks (that WinEx can take the place of).
    static func finderStacks() -> [URL] {
        dockOthers().compactMap { tile in
            guard tile["tile-type"] as? String == "directory-tile" else { return nil }
            return url(of: tile)
        }
    }

    private static func putInDock(_ stack: DockStack) {
        guard let app = bundleURL(for: stack) else { return }
        var replaced: [String: Any]?
        editDock { others in
            let result = adding(app, label: label(for: stack), replacing: stack.folder, to: others)
            replaced = result.replaced
            return result.others
        }
        if let replaced, var stored = self.stack(id: stack.id) {
            stored.finderTile = try? PropertyListSerialization.data(fromPropertyList: replaced, format: .binary, options: 0)
            // Shown and sorted as the Dock's stack was
            if let settings = settings(of: replaced) {
                stored.view = settings.view
                stored.sort = settings.sort
                stored.display = settings.display
            }
            update(stored)
            refreshIcon(stored)
        }
    }

    /// The view and order the Dock's own stack had («showas»: automatic, fan, grid, list;
    /// «arrangement»: name, date added, modified, created, kind).
    nonisolated static func settings(of tile: [String: Any]) -> (view: DockStack.View, sort: DockStack.Sort, display: DockStack.Display)? {
        guard let data = tile["tile-data"] as? [String: Any] else { return nil }
        let views: [DockStack.View] = [.automatic, .fan, .grid, .list]
        let sorts: [DockStack.Sort] = [.name, .added, .modified, .created, .kind]
        let show = (data["showas"] as? Int) ?? 0, arrangement = ((data["arrangement"] as? Int) ?? 1) - 1
        // «displayas»: 0 a stack, 1 the folder
        let display: DockStack.Display = (data["displayas"] as? Int) == 1 ? .folder : .stack
        return (views.indices.contains(show) ? views[show] : .automatic, sorts.indices.contains(arrangement) ? sorts[arrangement] : .name, display)
    }

    // MARK: Folders dragged from WinEx onto the Dock

    /// The Dock makes its own stack of a folder dropped on it; one dragged there from WinEx is
    /// made WinEx's in its place (Finder's drags are left alone). The Dock's list is read from
    /// the preferences system (its file on disk is written much later): as it was when the drag
    /// started — at the mouse press — and, after the drop, until a new tile of the folder shows
    /// (told by its GUID: the same folder may be in the Dock twice).
    private static var knownTiles: Set<String> = []
    private static var pressMonitor: Any?

    nonisolated static func tileKey(_ tile: [String: Any]) -> String? {
        guard tile["tile-type"] as? String == "directory-tile", let url = url(of: tile) else { return nil }
        let guid = (tile["GUID"] as? NSNumber)?.stringValue ?? ""
        return guid + "|" + url.standardizedFileURL.path
    }

    private static func rememberTiles() {
        knownTiles = Set(dockOthers().compactMap(tileKey))
        log.debug("Dock folder tiles remembered: \(knownTiles.count, privacy: .public)")
    }

    private static func watchDock() {
        rememberTiles()
        guard pressMonitor == nil else { return }
        // Every drag in WinEx starts with a press in it: the Dock's list before the drop
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { if Settings.dockStacksForNewFolders { rememberTiles() } }
            return event
        }
    }

    /// New folder tiles in the Dock since the press, with their folders.
    nonisolated static func newTiles(in others: [[String: Any]], known: Set<String>) -> [(key: String, path: String)] {
        others.compactMap { tile in
            guard let key = tileKey(tile), !known.contains(key), let path = url(of: tile)?.standardizedFileURL.path else { return nil }
            return (key, path)
        }
    }

    /// A drag from WinEx ended (anywhere): its folders may have landed on the Dock.
    static func dragEnded(_ session: NSDraggingSession, at point: NSPoint, operation: NSDragOperation) {
        // (Whatever the Dock answers: only a new tile of the same folder within seconds counts)
        let urls = session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let folders = Set(urls.filter(\.isBrowsableDirectory).map(\.standardizedFileURL.path))
        log.notice("drag ended: operation \(operation.rawValue, privacy: .public), \(urls.count, privacy: .public) urls, folders \(folders.sorted(), privacy: .public), on \(Settings.dockStacksForNewFolders, privacy: .public), known \(knownTiles.count, privacy: .public)")
        guard operation != .delete, Settings.dockStacksForNewFolders, !folders.isEmpty, isOverDock(point) else { return }
        let known = knownTiles
        let start = Date()
        // The Dock tells the preferences system of its new tile a few seconds later (3–10 seen):
        // the note shows at once, so the wait is seen
        DockStackProgress.show(near: point)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                let others = dockOthers()
                let found = newTiles(in: others, known: known).filter { folders.contains($0.path) }
                guard found.isEmpty, Date().timeIntervalSince(start) < 20 else {
                    timer.invalidate()
                    if found.isEmpty { DockStackProgress.hide() }
                    log.notice("Dock after the drop: \(others.compactMap(tileKey), privacy: .public); new of the folders: \(found.map(\.key), privacy: .public)")
                    for tile in found { adopt(tileKey: tile.key, folder: URL(fileURLWithPath: tile.path), near: point) }
                    return
                }
            }
        }
    }

    /// Whether a drop at `point` was on the Dock: in its strip at the screen's edge (or, with the
    /// Dock hidden, near that edge).
    static func isOverDock(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        let frame = screen.frame, visible = screen.visibleFrame
        switch CFPreferencesCopyAppValue("orientation" as CFString, dock) as? String ?? "bottom" {
        case "left": return point.x < max(visible.minX, frame.minX + 110)
        case "right": return point.x > min(visible.maxX, frame.maxX - 110)
        default: return point.y < max(visible.minY, frame.minY + 110)
        }
    }

    /// The Dock's new tile of `folder` becomes WinEx's stack (an existing one of the folder moves
    /// there), shown and sorted as the Dock set it; a note by the tile while the Dock restarts.
    private static func adopt(tileKey key: String, folder: URL, near point: NSPoint) {
        log.notice("adopting \(key, privacy: .public)")
        DockStackProgress.show(near: point)
        var stack: DockStack
        if let existing = self.stack(for: folder) {
            stack = existing
        } else {
            let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
            stack = DockStack(id: id, path: folder.standardizedFileURL.path, bookmark: try? folder.bookmarkData())
            all += [stack]
        }
        // (A stack already made keeps its app: it may be running)
        if bundleURL(for: stack) == nil { try? makeBundle(for: stack) }
        guard let app = bundleURL(for: stack) else {
            DockStackProgress.hide()
            return
        }
        var replaced: [String: Any]?
        editDock { others in
            var others = others
            // Not twice: WinEx's tile of this folder (if there) goes, the new one takes its place
            guard let i = others.firstIndex(where: { tileKey($0) == key }) else { return others }
            replaced = others[i]
            others[i] = tile(for: app, label: label(for: stack))
            if let old = others.indices.first(where: { $0 != i && url(of: others[$0])?.standardizedFileURL.path == app.standardizedFileURL.path }) {
                others.remove(at: old)
            }
            return others
        }
        if let replaced, var stored = self.stack(id: stack.id) {
            if stored.finderTile == nil {
                stored.finderTile = try? PropertyListSerialization.data(fromPropertyList: replaced, format: .binary, options: 0)
            }
            if let settings = settings(of: replaced) {
                stored.view = settings.view
                stored.sort = settings.sort
                stored.display = settings.display
            }
            update(stored)
        }
        launchInBackground(stack)
        self.stack(id: stack.id).map(refreshIcon)
    }

    // MARK: The Dock's list (its right side: folders, files and apps put there)

    private static let dock = "com.apple.dock" as CFString
    private static let othersKey = "persistent-others" as CFString

    private static func dockOthers() -> [[String: Any]] {
        CFPreferencesAppSynchronize(dock)
        return CFPreferencesCopyAppValue(othersKey, dock) as? [[String: Any]] ?? []
    }

    /// Changes the Dock's list and restarts the Dock to read it (as Finder's toolbar button does).
    private static func editDock(_ change: ([[String: Any]]) -> [[String: Any]]) {
        #if DEBUG
        if Scenario.isRequested { return }  // never the user's Dock
        #endif
        let before = dockOthers()
        let after = change(before)
        log.notice("Dock edit: \(before.count, privacy: .public) → \(after.count, privacy: .public) tiles, changed \(!(after as NSArray).isEqual(to: before), privacy: .public)")
        guard !(after as NSArray).isEqual(to: before) else { return }
        CFPreferencesSetAppValue(othersKey, after as CFArray, dock)
        CFPreferencesAppSynchronize(dock)
        // WinEx's own change: what's in the Dock now is known (a Finder stack put back isn't «new»)
        rememberTiles()
        DockStackProgress.waitForDock()
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Dock"]
        try? killall.run()
    }

    /// The tile the Dock keeps for an app put on its right side.
    nonisolated static func tile(for app: URL, label: String) -> [String: Any] {
        ["tile-type": "file-tile",
         "tile-data": ["file-data": ["_CFURLString": app.absoluteString, "_CFURLStringType": 15], "file-label": label] as [String: Any]]
    }

    nonisolated static func url(of tile: [String: Any]) -> URL? {
        guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
              let string = file["_CFURLString"] as? String else { return nil }
        // (Stored either as a file:// URL or, type 0, as a plain path)
        return string.hasPrefix("file://") ? URL(string: string) : URL(fileURLWithPath: string)
    }

    nonisolated static func index(of url: URL, in others: [[String: Any]]) -> Int? {
        let wanted = url.standardizedFileURL.path.trimmingCharacters(in: ["/"])
        return others.firstIndex { tile in Self.url(of: tile)?.standardizedFileURL.path.trimmingCharacters(in: ["/"]) == wanted }
    }

    /// The list with the app's tile: where the Dock's own stack of `folder` was (that tile is
    /// returned, to be put back later), or at the end.
    nonisolated static func adding(_ app: URL, label: String, replacing folder: URL?, to others: [[String: Any]]) -> (others: [[String: Any]], replaced: [String: Any]?) {
        guard index(of: app, in: others) == nil else { return (others, nil) }
        var others = others
        if let folder, let i = index(of: folder, in: others), others[i]["tile-type"] as? String == "directory-tile" {
            let replaced = others[i]
            others[i] = tile(for: app, label: label)
            return (others, replaced)
        }
        others.append(tile(for: app, label: label))
        return (others, nil)
    }

    /// The list without the app's tile; `restoring` (the Dock's own stack it replaced) goes back
    /// in its place unless the folder is in the Dock again by then.
    nonisolated static func removing(_ app: URL, restoring: [String: Any]?, from others: [[String: Any]]) -> [[String: Any]] {
        guard let i = index(of: app, in: others) else { return others }
        var others = others
        if let restoring, let folder = url(of: restoring), index(of: folder, in: others) == nil {
            others[i] = restoring
        } else {
            others.remove(at: i)
        }
        return others
    }

    // MARK: The stacks' apps

    /// Where the apps live (not indexed by Spotlight: they aren't apps to look for).
    static var bundlesRoot: URL {
        #if DEBUG
        if Scenario.isRequested { return FileManager.default.temporaryDirectory.appendingPathComponent("WinEx scenario Dock.noindex") }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WinEx/Dock.noindex")
    }

    static func bundleID(for stack: DockStack) -> String {
        (Bundle.main.bundleIdentifier ?? "dev.winex.WinEx") + ".stack." + stack.id
    }

    /// The name under the tile: the folder's, as the Dock shows it («Загрузки»).
    static func label(for stack: DockStack) -> String {
        let name = FileManager.default.displayName(atPath: stack.path)
        return name.isEmpty ? stack.folder.lastPathComponent : name
    }

    static func bundleURL(for stack: DockStack) -> URL? {
        let folder = bundlesRoot.appendingPathComponent(stack.id)
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "app" }
    }

    private static var helperBinary: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WinExStack") }

    /// Makes (or makes again) the stack's app: WinEx's helper, an Info.plist saying which stack it
    /// is and where WinEx is, the icon, an ad-hoc signature.
    static func makeBundle(for stack: DockStack) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperBinary.path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: helperBinary.path]) }
        // Made again where it was: the Dock's tile points at that path (a renamed folder's app
        // keeps its file name; the Dock shows the name inside it)
        // (A file name can't have «/»; «:» shows as «/» in Finder)
        let app = bundleURL(for: stack)
            ?? bundlesRoot.appendingPathComponent(stack.id).appendingPathComponent(label(for: stack).replacingOccurrences(of: "/", with: ":") + ".app")
        try? fm.removeItem(at: app)
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: helperBinary, to: contents.appendingPathComponent("MacOS/WinExStack"))
        let plist: [String: Any] = [
            "CFBundleExecutable": "WinExStack",
            "CFBundleIdentifier": bundleID(for: stack),
            "CFBundleName": label(for: stack),
            "CFBundleDisplayName": label(for: stack),
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "icon",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": helperVersion,
            "LSMinimumSystemVersion": "26.0",
            "LSUIElement": true,
            "NSPrincipalClass": "NSApplication",
            // Anything dropped on the tile (never the app files open in)
            "CFBundleDocumentTypes": [["CFBundleTypeName": "Item", "CFBundleTypeRole": "Viewer",
                                       "LSHandlerRank": "None", "LSItemContentTypes": ["public.item"]]],
            "WinExStackID": stack.id,
            "WinExBundleID": Bundle.main.bundleIdentifier ?? "dev.winex.WinEx",
            "WinExAppPath": Bundle.main.bundleURL.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        // (Icons for now; the previews follow in `refreshIcon`)
        let items = DockStackPanel.contents(of: stack.folder, sort: stack.sortOrder).prefix(stack.display == .folder ? 1 : 3)
        try writeIcon(icon(for: stack, pictures: items.map(\.icon)), to: contents.appendingPathComponent("Resources/icon.icns"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        setCustomIcon(icon(for: stack, pictures: items.map(\.icon)), on: app)
        LSRegisterURL(app as CFURL, true)
    }

    /// The picture set as the app's own custom icon (after signing: it's a file the signature
    /// doesn't cover). macOS 26 puts an app's icon that isn't a full rounded square on a grey
    /// plate in the Dock — not a custom one, so the stack looks as Finder's.
    private static func setCustomIcon(_ image: NSImage, on app: URL) {
        NSWorkspace.shared.setIcon(image, forFile: app.path, options: [])
    }

    /// Changes with WinEx's helper: a stack's app made by another version is made again.
    private static var helperVersion: String {
        let size = (try? helperBinary.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let date = (try? helperBinary.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(size).\(Int(date))"
    }

    /// The tile's picture as the Dock draws its stacks: the first items (`pictures`, previews of
    /// documents) stacked a little askew, or the folder's icon with the first one peeking out of
    /// it; an empty folder is its icon.
    static func icon(for stack: DockStack, pictures: [NSImage]) -> NSImage {
        let folder = FileItem(url: stack.folder).icon
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            func shadowed(_ draw: () -> Void) {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
                shadow.shadowBlurRadius = 16
                shadow.shadowOffset = NSSize(width: 0, height: -8)
                shadow.set()
                draw()
                NSGraphicsContext.restoreGraphicsState()
            }
            if stack.display == .folder || pictures.isEmpty {
                folder.draw(in: rect)
                guard stack.display == .folder, let first = pictures.first else { return true }
                // Out of the folder: only what's above its front shows
                let box = NSRect(x: rect.width * 0.27, y: rect.height * 0.4, width: rect.width * 0.46, height: rect.height * 0.54)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: 0, y: rect.height * 0.655, width: rect.width, height: rect.height)).addClip()
                shadowed { first.draw(in: DesktopView.aspectFit(first.size, in: box)) }
                NSGraphicsContext.restoreGraphicsState()
                return true
            }
            // The stack: the first on top, the next two behind it, turned a little
            let box = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.08)
            let turns: [CGFloat] = [0, -5, 6]
            for (k, picture) in pictures.prefix(3).enumerated().reversed() {
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: rect.midX, yBy: rect.midY)
                t.rotate(byDegrees: turns[k])
                t.scale(by: k == 0 ? 1 : 0.95)
                t.translateX(by: -rect.midX, yBy: -rect.midY + (k == 0 ? 0 : 10))
                t.concat()
                shadowed { picture.draw(in: DesktopView.aspectFit(picture.size, in: box)) }
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    /// The first items' pictures (previews of documents, icons of folders and apps), then `done`.
    static func pictures(for stack: DockStack, done: @escaping @MainActor ([NSImage]) -> Void) {
        let count = stack.display == .folder ? 1 : 3
        let items = Array(DockStackPanel.contents(of: stack.folder, sort: stack.sortOrder).prefix(count))
        var pictures: [NSImage?] = items.map { $0.isFolder || $0.url.pathExtension == "app" ? $0.icon : nil }
        let group = DispatchGroup()
        for (i, item) in items.enumerated() where pictures[i] == nil {
            group.enter()
            let request = QLThumbnailGenerator.Request(fileAt: AliasIcon.previewSource(item), size: CGSize(width: 512, height: 512),
                                                       scale: 2, representationTypes: .thumbnail)
            request.iconMode = true
            let fallback = item.icon
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                let image = representation?.nsImage
                DispatchQueue.main.async {
                    pictures[i] = image ?? fallback
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(pictures.compactMap { $0 }) } }
    }

    /// Draws the tile's picture again (the folder changed, or how it's shown): written into the
    /// stack's app, signed again, and LaunchServices told — the Dock picks up the new icon.
    static func refreshIcon(_ stack: DockStack) {
        #if DEBUG
        if Scenario.isRequested && ProcessInfo.processInfo.environment["WINEX_SCENARIO"] != "dockstack" { return }
        #endif
        pictures(for: stack) { pictures in
            guard let app = bundleURL(for: stack) else { return }
            let image = icon(for: stack, pictures: pictures)
            let target = app.appendingPathComponent("Contents/Resources/icon.icns")
            guard (try? writeIcon(image, to: target)) != nil else { return }
            DispatchQueue.global(qos: .utility).async {
                let sign = Process()
                sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                sign.arguments = ["--force", "--sign", "-", app.path]
                sign.standardOutput = FileHandle.nullDevice
                sign.standardError = FileHandle.nullDevice
                try? sign.run()
                sign.waitUntilExit()
                DispatchQueue.main.async {
                    setCustomIcon(image, on: app)
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
                    LSRegisterURL(app as CFURL, true)
                    NSWorkspace.shared.noteFileSystemChanged(app.path)
                }
            }
        }
    }

    /// Each stack's folder followed: what's in it changes the tile's picture (a moment later).
    private static var watchers: [String: DirectoryWatcher] = [:]

    static func watchFolders() {
        let ids = Set(all.map(\.id))
        watchers = watchers.filter { ids.contains($0.key) }
        for stack in all where watchers[stack.id] == nil {
            guard let folder = folder(of: stack) else { continue }
            watchers[stack.id] = DirectoryWatcher(url: folder, delay: 2) {
                if let current = DockStacks.stack(id: stack.id) { refreshIcon(current) }
            }
        }
    }

    private static func writeIcon(_ image: NSImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 7, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for side in [16, 32, 64, 128, 256, 512, 1024] {
            // Drawn at that many pixels
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            if let cg = rep.cgImage { CGImageDestinationAddImage(destination, cg, nil) }
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: Running

    /// At launch: each stack's app made again if this WinEx's helper is another, and started in
    /// the background (the first click on it is then as quick as the others).
    static func start() {
        DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            guard let id = info["id"] as? String, let action = info["action"] as? String else { return }
            let x = (info["x"] as? NSNumber)?.doubleValue ?? 0, y = (info["y"] as? NSNumber)?.doubleValue ?? 0
            let paths = info["paths"] as? [String] ?? []
            MainActor.assumeIsolated { handle(id: id, action: action, at: NSPoint(x: x, y: y), paths: paths) }
        }
        // Started by a stack's app (WinEx wasn't running): --stack <id> <action> <x> <y> [paths…]
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--stack"), arguments.count > i + 4 {
            let id = arguments[i + 1], action = arguments[i + 2]
            let point = NSPoint(x: Double(arguments[i + 3]) ?? 0, y: Double(arguments[i + 4]) ?? 0)
            let paths = Array(arguments[(i + 5)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { handle(id: id, action: action, at: point, paths: paths) }
        }
        #if DEBUG
        if Scenario.isRequested { return }
        #endif
        watchDock()
        for stack in all {
            let plist = bundleURL(for: stack).flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
            if plist?["CFBundleVersion"] as? String != helperVersion || plist?["WinExAppPath"] as? String != Bundle.main.bundleURL.path {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(for: stack)) { running.terminate() }
                guard (try? makeBundle(for: stack)) != nil else { continue }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { launchInBackground(stack); refreshIcon(stack) }
        }
        watchFolders()
        NotificationCenter.default.addObserver(forName: changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { watchFolders() }
        }
    }

    static func launchInBackground(_ stack: DockStack) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(for: stack)).isEmpty,
              let app = bundleURL(for: stack) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--background"]
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    static func handle(id: String, action: String, at point: NSPoint, paths: [String]) {
        guard let stack = stack(id: id) else { return }
        guard let folder = folder(of: stack) else {
            NSSound.beep()
            return
        }
        switch action {
        case "drop":
            let urls = paths.map(URL.init(fileURLWithPath:)).filter { $0.deletingLastPathComponent().standardizedFileURL.path != folder.standardizedFileURL.path }
            guard !urls.isEmpty else { return }
            // As onto the Dock's folder: moved on the same disk, copied from another
            FileOps.transfer(urls, to: folder, copy: !FileDrop.sameVolume(urls[0], folder))
        default:
            DockStackPanel.toggle(stack, folder: folder, mouse: point)
        }
    }
}

// MARK: - Asking

extension DockStacks {
    /// «Добавить в Dock»: asks first (the Dock restarts), then puts the folder there.
    static func confirmAndAdd(_ folder: URL, window: NSWindow?) {
        let name = FileManager.default.displayName(atPath: folder.path)
        let replacing = finderStacks().contains { $0.standardizedFileURL.path == folder.standardizedFileURL.path }
        let alert = NSAlert()
        alert.messageText = L("Добавить «%@» в Dock как стопку WinEx?", name)
        alert.informativeText = (replacing ? L("Она займёт место стопки Finder этой папки; если её убрать, стопка Finder вернётся.") + " " : "")
            + L("Нажатие на неё покажет папку веером, сеткой или списком, как стопки Dock, но откроет её в WinEx. Dock перезапустится на секунду.")
        alert.addButton(withTitle: L("Добавить"))
        alert.addButton(withTitle: L("Отменить"))
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            do { try add(folder) } catch {
                let failed = NSAlert()
                failed.messageText = L("Не удалось добавить папку в Dock")
                failed.informativeText = error.localizedDescription
                failed.runModal()
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: answer) } else { NSApp.activate(); answer(alert.runModal()) }
    }

    /// The folder context menu's item: «Добавить в Dock» (or «Убрать из Dock» for a stack's folder).
    static func menuItem(for urls: [URL]) -> NSMenuItem? {
        guard urls.count == 1, let folder = urls.first, folder.isBrowsableDirectory else { return nil }
        let item: NSMenuItem
        if let stack = stack(for: folder), isInDock(stack) {
            item = NSMenuItem(title: L("Убрать из Dock"), action: #selector(StackOptions.removeStack(_:)), keyEquivalent: "")
            item.representedObject = stack.id
        } else {
            item = NSMenuItem(title: L("Добавить в Dock"), action: #selector(StackOptions.addToDock(_:)), keyEquivalent: "")
            item.representedObject = folder
        }
        item.target = StackOptions.shared
        item.image = MenuStyle.symbol("dock.rectangle")
        return item
    }
}

extension StackOptions {
    @objc func addToDock(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        DockStacks.confirmAndAdd(folder, window: NSApp.keyWindow)
    }
}

/// Settings ▸ Finder ▸ «Папки в Dock»: WinEx's stacks (each with whether it's in the Dock, its
/// view, taking it out) and «Добавить…» — the Dock's own stacks first, then any folder.
@MainActor
final class DockStacksSettingsView: NSStackView {
    private let observers = Observers()
    private let add = NSPopUpButton(frame: .zero, pullsDown: true)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        observers.add(DockStacks.changed) { [weak self] in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for stack in DockStacks.all {
            let icon = NSImageView(image: FileItem(url: stack.folder).icon)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let name = NSTextField(labelWithString: DockStacks.label(for: stack))
            name.toolTip = stack.path
            let state = NSTextField(labelWithString: DockStacks.isInDock(stack) ? "" : L("(нет в Dock)"))
            state.textColor = .secondaryLabelColor
            let view = NSPopUpButton(frame: .zero, pullsDown: false)
            view.controlSize = .small
            for option in DockStack.View.allCases {
                view.addItem(withTitle: DockStack.title(option))
                view.lastItem?.representedObject = [stack.id, option.rawValue]
            }
            view.selectItem(at: DockStack.View.allCases.firstIndex(of: stack.view) ?? 0)
            view.target = StackOptions.shared
            view.action = #selector(StackOptions.setViewFromPopUp(_:))
            let back = NSButton(title: L("Вернуть в Dock"), target: self, action: #selector(putBack(_:)))
            back.controlSize = .small
            back.identifier = NSUserInterfaceItemIdentifier(stack.id)
            back.isHidden = DockStacks.isInDock(stack)
            let remove = NSButton(title: L("Убрать"), target: self, action: #selector(remove(_:)))
            remove.controlSize = .small
            remove.identifier = NSUserInterfaceItemIdentifier(stack.id)
            let row = NSStackView(views: [icon, name, state, view, back, remove])
            row.spacing = 6
            addArrangedSubview(row)
        }
        add.removeAllItems()
        add.addItem(withTitle: L("Добавить папку в Dock"))
        let ours = Set(DockStacks.all.map { $0.folder.standardizedFileURL.path })
        let finder = DockStacks.finderStacks().filter { !ours.contains($0.standardizedFileURL.path) }
        for folder in finder {
            add.addItem(withTitle: L("Заменить стопку Finder «%@»", FileManager.default.displayName(atPath: folder.path)))
            add.lastItem?.representedObject = folder
            add.lastItem?.image = {
                let image = NSWorkspace.shared.icon(forFile: folder.path)
                image.size = NSSize(width: 16, height: 16)
                return image
            }()
        }
        if !finder.isEmpty { add.menu?.addItem(.separator()) }
        add.addItem(withTitle: L("Другая папка…"))
        add.target = self
        add.action = #selector(addChosen(_:))
        addArrangedSubview(add)
        let automatic = NSButton(checkboxWithTitle: L("Папки, перетащенные из WinEx в Dock, — стопками WinEx"), target: self, action: #selector(toggleAutomatic(_:)))
        automatic.state = Settings.dockStacksForNewFolders ? .on : .off
        addArrangedSubview(automatic)
    }

    @objc private func toggleAutomatic(_ sender: NSButton) {
        Settings.dockStacksForNewFolders = sender.state == .on
    }

    @objc private func addChosen(_ sender: NSPopUpButton) {
        if let folder = sender.selectedItem?.representedObject as? URL {
            return DockStacks.confirmAndAdd(folder, window: window)
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Добавить")
        let chosen: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DockStacks.confirmAndAdd(url, window: self?.window)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: chosen) } else { chosen(panel.runModal()) }
    }

    @objc private func remove(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let stack = DockStacks.stack(id: id) else { return }
        DockStacks.remove(stack)
    }

    @objc private func putBack(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let stack = DockStacks.stack(id: id) else { return }
        try? DockStacks.add(stack.folder)
        rebuild()
    }
}

extension StackOptions {
    @objc func setViewFromPopUp(_ sender: NSPopUpButton) {
        guard let pair = sender.selectedItem?.representedObject as? [String], pair.count == 2, var stack = DockStacks.stack(id: pair[0]),
              let view = DockStack.View(rawValue: pair[1]) else { return }
        stack.view = view
        DockStacks.update(stack)
    }
}

/// While a folder dragged from WinEx becomes a WinEx stack: a small note by the drop point
/// («Создаётся стопка WinEx…» with a spinner) until the Dock has restarted with it.
@MainActor
enum DockStackProgress {
    private static var panel: NSPanel?
    private static var waiting: Timer?

    static func show(near point: NSPoint) {
        guard panel == nil else { return }  // (shown at the drop already)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: L("Создаётся стопка WinEx…"))
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        let row = NSStackView(views: [spinner, label])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        let size = row.fittingSize
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = size.height / 2
        background.layer?.masksToBounds = true
        row.frame = background.bounds
        background.addSubview(row)
        let anchor = StackAnchor.at(point)
        var origin = NSPoint(x: anchor.point.x - size.width / 2, y: anchor.point.y + 10)
        if anchor.edge == .left { origin = NSPoint(x: anchor.point.x + 10, y: anchor.point.y - size.height / 2) }
        if anchor.edge == .right { origin = NSPoint(x: anchor.point.x - size.width - 10, y: anchor.point.y - size.height / 2) }
        origin.x = min(max(origin.x, anchor.frame.minX + 8), anchor.frame.maxX - size.width - 8)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = background
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel
        // Never left behind
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak panel] in if let panel, panel === self.panel { hide() } }
    }

    /// The Dock is about to restart: the note goes once it's back (a new Dock process, a moment
    /// for it to draw its tiles).
    static func waitForDock() {
        guard panel != nil else { return }
        let before = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let start = Date()
        waiting?.invalidate()
        waiting = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let now = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
                guard (now != nil && now != before) || Date().timeIntervalSince(start) > 6 else { return }
                timer.invalidate()
                waiting = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { hide() }
            }
        }
    }

    static func hide(animated: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        guard animated else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }
}
