import AppKit
import Quartz
import UniformTypeIdentifiers

/// A device's files as WinEx reaches them: the Documents of apps that share files (Finder's
/// «Файлы» tab) and the camera roll's folders (DCIM). Connections are kept and opened again when
/// the device drops them (a phone over Wi‑Fi asleep); everything runs on the store's own queue.
final class DeviceFileStore: @unchecked Sendable {
    enum Root: Hashable, Sendable {
        /// The media folder (`com.apple.afc`): DCIM.
        case media
        /// An app's container (house_arrest): its Documents.
        case app(String)
    }

    struct App: Sendable {
        let id: String
        let name: String
    }

    let udid: String
    let queue: DispatchQueue
    private var lockdown: MobileDeviceLink.Lockdown?
    private var conduits: [Root: MobileDeviceLink.AFC] = [:]

    private static var stores: [String: DeviceFileStore] = [:]
    private static let storesLock = NSLock()

    static func store(_ udid: String) -> DeviceFileStore {
        storesLock.lock()
        defer { storesLock.unlock() }
        if let store = stores[udid] { return store }
        let store = DeviceFileStore(udid: udid)
        stores[udid] = store
        return store
    }

    private init(udid: String) {
        self.udid = udid
        queue = DispatchQueue(label: "dev.winex.device-files")
    }

    private func session() throws -> MobileDeviceLink.Lockdown {
        if let lockdown { return lockdown }
        let lockdown = try MobileDeviceLink.Lockdown(MobileDevices.link(udid))
        try lockdown.startSession()
        self.lockdown = lockdown
        return lockdown
    }

    private func conduit(_ root: Root) throws -> MobileDeviceLink.AFC {
        if let afc = conduits[root] { return afc }
        let afc: MobileDeviceLink.AFC
        switch root {
        case .media:
            afc = MobileDeviceLink.AFC(try session().startService("com.apple.afc"))
        case .app(let id):
            let service = try session().startService("com.apple.mobile.house_arrest")
            let reply = try service.request(["Command": "VendDocuments", "Identifier": id])
            guard reply["Status"] as? String == "Complete" else { throw MobileDeviceLink.Failure(L("Программа не открыла свои файлы.")) }
            afc = MobileDeviceLink.AFC(service)
        }
        conduits[root] = afc
        return afc
    }

    /// Runs `body` with a root's conduit; a dropped connection is opened again once. On the queue.
    func with<T>(_ root: Root, _ body: (MobileDeviceLink.AFC) throws -> T) throws -> T {
        do {
            return try body(conduit(root))
        } catch let refusal as MobileDeviceLink.AFC.Refusal {
            throw refusal
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            MobileDevices.log.info("\(self.udid, privacy: .public): reconnecting after \(String(describing: error), privacy: .public)")
            reset()
            return try body(conduit(root))
        }
    }

    func reset() {
        lockdown = nil
        conduits = [:]
    }

    /// The apps that share files with a computer (UIFileSharingEnabled), by name. On the queue.
    func apps() throws -> [App] {
        func browse() throws -> [App] {
            let proxy = try session().startService("com.apple.mobile.installation_proxy")
            try proxy.send(["Command": "Browse", "ClientOptions": [
                "ApplicationType": "User",
                "ReturnAttributes": ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "UIFileSharingEnabled"],
            ]])
            var apps: [App] = []
            while true {
                let reply = try proxy.receive()
                for app in reply["CurrentList"] as? [[String: Any]] ?? [] where app["UIFileSharingEnabled"] as? Bool == true {
                    guard let id = app["CFBundleIdentifier"] as? String else { continue }
                    apps.append(App(id: id, name: app["CFBundleDisplayName"] as? String ?? app["CFBundleName"] as? String ?? id))
                }
                if reply["Status"] as? String == "Complete" || reply["Error"] != nil { break }
            }
            return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        do { return try browse() } catch {
            reset()
            return try browse()
        }
    }

    /// Apps' icons as the Home Screen shows them. On the queue.
    func icons(_ ids: [String]) -> [String: NSImage] {
        guard let board = try? session().startService("com.apple.springboardservices") else { return [:] }
        var icons: [String: NSImage] = [:]
        for id in ids {
            guard let reply = try? board.request(["command": "getIconPNGData", "bundleId": id]),
                  let data = reply["pngData"] as? Data, let image = NSImage(data: data) else { continue }
            icons[id] = image
        }
        return icons
    }

    /// Copies a device file or folder to `destination` (the folder's whole contents). On the queue.
    func download(_ root: Root, _ path: String, isDirectory: Bool, to destination: URL, progress: @escaping (Int64) -> Bool) throws {
        let fm = FileManager.default
        guard isDirectory else {
            return try with(root) { try $0.download(path, to: destination, progress: progress) }
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try with(root) { try $0.walk(path) }
        var done: Int64 = 0
        for (entry, relative) in items {
            let target = destination.appendingPathComponent(relative)
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                let before = done
                try with(root) { try $0.download(entry.path, to: target) { progress(before + $0) } }
                done += entry.size
            }
        }
    }

    /// Copies Mac files and folders into a device folder. On the queue.
    func upload(_ urls: [URL], to folder: String, root: Root, progress: @escaping (Int64) -> Bool) throws {
        let fm = FileManager.default
        var done: Int64 = 0
        func send(_ url: URL, to path: String) throws {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                try with(root) { afc in
                    do { try afc.makeDirectory(path) } catch let refusal as MobileDeviceLink.AFC.Refusal where refusal.code == 16 {}
                }
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                    try send(child, to: path + "/" + child.lastPathComponent)
                }
            } else {
                let before = done
                try with(root) { try $0.upload(url, to: path) { progress(before + $0) } }
                done += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        for url in urls { try send(url, to: folder + "/" + url.lastPathComponent) }
    }
}

/// The «Файлы» tab of a device's page: Finder's list of apps that share files, as a tree (folders
/// open in place) or one folder at a time (entered by double-click, the window's path, back and up
/// following). Files are dragged out to copy them to the Mac and dragged onto an app or folder to
/// copy them to the device; double-click opens a copy.
@MainActor
final class DeviceFilesView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSCollectionViewDataSource,
                                   NSCollectionViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate {
    /// Read in the background only by its constants (root, path, name…); the rest on the main thread.
    final class Node: @unchecked Sendable {
        let root: DeviceFileStore.Root
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int64?
        let modified: Date?
        /// An app's row (its Documents).
        let isApp: Bool
        weak var parent: Node?
        var children: [Node]?
        var loading = false
        var icon: NSImage?

        init(root: DeviceFileStore.Root, path: String, name: String, isDirectory: Bool, size: Int64? = nil,
             modified: Date? = nil, isApp: Bool = false, parent: Node? = nil) {
            self.root = root; self.path = path; self.name = name; self.isDirectory = isDirectory
            self.size = size; self.modified = modified; self.isApp = isApp; self.parent = parent
        }
    }

    /// The status bar's text (how many, what's being copied).
    var onStatus: ((String) -> Void)?
    /// A folder entered (flat mode): its place, «/<app id>/<folders…>» under the app's Documents.
    var onEnter: ((String) -> Void)?
    /// Something copied to the device or deleted from it (its free space changed).
    var onDeviceChanged: (() -> Void)?
    /// Apps' names by id, for the window's path.
    static var appNames: [String: [String: String]] = [:]
    /// One folder at a time instead of the tree.
    private(set) var flat = false
    /// Flat: the folder shown (nil: the apps).
    private var current: Node?
    /// A folder to show once the apps are read.
    private var pendingPath: String?
    private let outline = DeviceOutlineView()
    /// Flat mode: the folder's items as icons (WinEx's «Обычные значки»).
    private let grid = DeviceIconGrid()
    /// Space: Quick Look of the files selected.
    private let preview = DevicePreview()
    private var store: DeviceFileStore?
    private var top: [Node]?
    private var message: String?
    let messageLabel = NSTextField(labelWithString: "")
    /// The spinner and the message, laid over the list by the page (inside the scroll view the
    /// list draws over them).
    let overlay = DeviceOverlayView()
    /// Turns while the apps or the folder entered are being read.
    private let spinner = NSProgressIndicator()
    private(set) var spinning = false
    /// Quick Look waits for a file to come from the device.
    private var previewLoading = false
    private var generation = 0
    private var busy: String?

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        let columns: [(String, String, CGFloat)] = [("name", L("Имя"), 320), ("size", L("Размер"), 90), ("modified", L("Дата изменения"), 170)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            outline.addTableColumn(column)
            if id == "name" { outline.outlineTableColumn = column }
        }
        outline.style = .inset
        outline.rowHeight = 24
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.onDelete = { [weak self] in self?.deleteSelected(nil) }
        outline.onSpace = { [weak self] in self?.quickLook() }
        outline.preview = preview
        preview.onLoading = { [weak self] text in
            guard let self else { return }
            previewLoading = text != nil
            setBusy(text)
            updateSpinner()
        }
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.registerForDraggedTypes([.fileURL])
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        documentView = outline

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = ViewMode.mediumIcons.itemSize
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.clear]
        grid.dataSource = self
        grid.delegate = self
        grid.register(DeviceIconItem.self, forItemWithIdentifier: DeviceIconItem.identifier)
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.registerForDraggedTypes([.fileURL])
        grid.onOpen = { [weak self] index in
            guard let self, index < shown.count else { return }
            activate(shown[index])
        }
        grid.onDelete = { [weak self] in self?.deleteSelected(nil) }
        grid.onSpace = { [weak self] in self?.quickLook() }
        grid.preview = preview
        let gridMenu = NSMenu()
        gridMenu.delegate = self
        grid.menu = gridMenu

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(messageLabel)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -30),
            messageLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -60),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The view in use shows the items anew.
    private func reloadView() {
        if flat { grid.reloadData() } else { outline.reloadData() }
        updateSpinner()
    }

    /// The spinner while what's shown is still being read (the apps, or the folder entered).
    private func updateSpinner() {
        let waiting = isLoadingTop || previewLoading || (flat && current?.loading == true)
        spinning = waiting
        // A folder read and empty says so (the apps' own messages are set where they're read)
        if flat, let current, !isLoadingTop {
            setMessage(current.children?.isEmpty == true ? L("Папка пуста") : nil)
        }
        if waiting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// What has the keyboard: the tree or the icons.
    var focusView: NSView { flat ? grid : outline }

    /// Flat mode on or off; the apps again either way.
    func setFlat(_ on: Bool) {
        flat = on
        current = nil
        if top?.isEmpty == false { setMessage(nil) }
        documentView = on ? grid : outline
        reloadView()
        updateStatus()
    }

    /// Shows a folder (`/<app id>/<folders…>`, "" for the apps) in flat mode.
    func open(_ udid: String, path: String) {
        if store !== DeviceFileStore.store(udid) || top == nil {
            pendingPath = path
            if store !== DeviceFileStore.store(udid) || !isLoadingTop { show(udid) }
            return
        }
        let parts = path.split(separator: "/").map(String.init)
        guard let id = parts.first, let app = top?.first(where: { $0.root == .app(id) }) else {
            current = nil
            reloadView()
            return updateStatus()
        }
        let rest = parts.dropFirst()
        let node = rest.isEmpty ? app
            : Node(root: app.root, path: "/Documents/" + rest.joined(separator: "/"), name: rest.last ?? app.name, isDirectory: true)
        current = node
        setMessage(nil)
        if node.children == nil {
            reloadView()
            load(node)
        } else {
            reloadView()
        }
        updateStatus()
    }

    private var isLoadingTop = false

    /// A folder's place for the window (see `onEnter`).
    private func place(of node: Node) -> String? {
        guard case .app(let id) = node.root else { return nil }
        return "/" + id + node.path.dropFirst("/Documents".count)
    }

    /// Shows a device's apps, read anew.
    func show(_ udid: String) {
        let store = DeviceFileStore.store(udid)
        self.store = store
        generation += 1
        let generation = generation
        top = nil
        current = nil
        isLoadingTop = true
        setMessage(L("Загрузка…"))
        reloadView()
        store.queue.async {
            let result: Result<[Node], Error> = Result {
                try store.apps().map { Node(root: .app($0.id), path: "/Documents", name: $0.name, isDirectory: true, isApp: true) }
            }
            DispatchQueue.main.async {
                guard self.generation == generation else { return }
                self.isLoadingTop = false
                self.updateSpinner()
                switch result {
                case .success(let nodes):
                    self.top = nodes
                    Self.appNames[udid] = Dictionary(nodes.compactMap { node in
                        if case .app(let id) = node.root { (id, node.name) } else { nil }
                    }, uniquingKeysWith: { a, _ in a })
                    self.setMessage(nodes.isEmpty ? L("На устройстве нет программ, которые обмениваются файлами с компьютером.") : nil)
                    self.reloadView()
                    self.updateStatus()
                    self.loadIcons(nodes)
                    if let path = self.pendingPath {
                        self.pendingPath = nil
                        self.open(udid, path: path)
                    }
                case .failure(let error):
                    self.setMessage(L("Не удалось прочитать устройство: %@", String(describing: error)))
                }
            }
        }
    }

    private func loadIcons(_ apps: [Node]) {
        guard let store else { return }
        let ids = apps.compactMap { node -> String? in if case .app(let id) = node.root { id } else { nil } }
        store.queue.async {
            let icons = store.icons(ids)
            DispatchQueue.main.async {
                for node in apps { if case .app(let id) = node.root { node.icon = icons[id] } }
                self.reloadView()
            }
        }
    }

    private func setMessage(_ text: String?) {
        message = text
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
    }

    var statusText: String {
        if let busy { return busy }
        if flat, let current {
            if current.children == nil { return L("Загрузка…") }
            let count = current.children?.count ?? 0
            return "\(count) \(plural(count, L("объект"), L("объекта"), L("объектов")))"
        }
        let count = top?.count ?? 0
        return "\(count) \(plural(count, L("программа"), L("программы"), L("программ")))"
    }

    /// What the list shows at its top level: the apps, or (flat) the folder's items.
    var shown: [Node] {
        if flat, let current { return current.children ?? [] }
        return top ?? []
    }

    private func updateStatus() { onStatus?(statusText) }

    private func setBusy(_ text: String?) {
        busy = text
        updateStatus()
    }

    // MARK: Loading children

    private func load(_ node: Node, then: (() -> Void)? = nil) {
        guard let store, !node.loading else { return }
        node.loading = true
        updateSpinner()
        store.queue.async {
            let result = Result { try store.with(node.root) { try $0.entries(node.path) } }
            DispatchQueue.main.async {
                node.loading = false
                self.updateSpinner()
                switch result {
                case .success(let entries):
                    node.children = entries
                        .filter { !$0.name.hasPrefix(".") }
                        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
                        .map { Node(root: node.root, path: $0.path, name: $0.name, isDirectory: $0.isDirectory,
                                    size: $0.isDirectory ? nil : $0.size, modified: $0.modified, parent: node) }
                case .failure(let error):
                    node.children = []
                    self.report(error)
                }
                if self.flat {
                    if node === self.current {
                        self.reloadView()
                        self.updateStatus()
                    }
                } else {
                    self.outline.reloadItem(node, reloadChildren: true)
                }
                then?()
            }
        }
    }

    /// Reads a folder again (after copying into it, deleting, a new folder).
    private func refresh(_ node: Node) {
        node.children = nil
        if flat {
            if node === current { load(node) }
            return
        }
        if outline.isItemExpanded(node) { load(node) } else { outline.reloadItem(node, reloadChildren: true) }
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node, node.children == nil else { return }
        load(node)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return shown.count }
        if flat { return 0 }
        return node.children?.count ?? (node.isDirectory ? 1 : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return shown[index] }
        // Not read yet: one «Загрузка…» row until it is
        return node.children?[index] ?? Self.loadingRow
    }

    private static let loadingRow = "loading"

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !flat && (item as? Node)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let column = tableColumn?.identifier.rawValue ?? "name"
        guard let node = item as? Node else {
            return column == "name" ? Self.cell(text: L("Загрузка…"), icon: nil, secondary: true) : nil
        }
        switch column {
        case "size":
            return Self.cell(text: node.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? (node.isApp ? "" : "—"), icon: nil, secondary: true)
        case "modified":
            return Self.cell(text: node.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "", icon: nil, secondary: true)
        default:
            return Self.cell(text: node.name, icon: icon(for: node), secondary: false)
        }
    }

    private func icon(for node: Node) -> NSImage {
        if let icon = node.icon { return icon }
        if node.isApp { return NSWorkspace.shared.icon(for: .application) }
        if node.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let type = UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    private static func cell(text: String, icon: NSImage?, secondary: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        var leading = cell.leadingAnchor
        if let icon {
            let image = NSImageView(image: icon)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
            ])
            leading = image.trailingAnchor
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: icon == nil ? 2 : 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Opening

    private var selectedNodes: [Node] {
        if flat {
            return grid.selectionIndexPaths.sorted().compactMap { $0.item < shown.count ? shown[$0.item] : nil }
        }
        let rows = outline.clickedRow >= 0 && !outline.selectedRowIndexes.contains(outline.clickedRow)
            ? IndexSet(integer: outline.clickedRow) : outline.selectedRowIndexes
        return rows.compactMap { outline.item(atRow: $0) as? Node }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        activate(node)
    }

    /// Double-click: a folder entered (flat) or opened in place (tree), a file opened.
    private func activate(_ node: Node) {
        if node.isDirectory, flat {
            if let place = place(of: node) { onEnter?(place) }
        } else if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            open([node])
        }
    }

    /// Opens copies of device files (in a temporary folder) with their apps.
    @objc private func openSelected(_ sender: Any?) { open(selectedNodes.filter { !$0.isDirectory }) }

    private func open(_ nodes: [Node]) {
        guard !nodes.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WinEx Devices/\(UUID().uuidString)")
        copy(nodes, to: folder) { urls in urls.forEach { NSWorkspace.shared.open($0) } }
    }

    /// «Скопировать на Mac…»: into a folder picked.
    @objc private func copyToMac(_ sender: Any?) {
        let nodes = selectedNodes
        guard !nodes.isEmpty, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Скопировать")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.copy(nodes, to: folder) { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    /// Copies nodes into a Mac folder (names made unique), then `done` with the copies.
    private func copy(_ nodes: [Node], to folder: URL, done: @escaping ([URL]) -> Void) {
        guard let store else { return }
        let total = nodes.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        setBusy(L("Копирование с устройства…"))
        store.queue.async {
            var copied: [URL] = []
            var failure: Error?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var done: Int64 = 0
                for node in nodes {
                    let target = Self.unique(folder.appendingPathComponent(node.name))
                    let before = done
                    try store.download(node.root, node.path, isDirectory: node.isDirectory, to: target) { bytes in
                        if total > 0 {
                            let percent = Int(Double(before + bytes) / Double(total) * 100)
                            DispatchQueue.main.async { self.setBusy(L("Копирование «%@»… %@ %", node.name, String(min(percent, 100)))) }
                        }
                        return true
                    }
                    done += node.size ?? 0
                    copied.append(target)
                }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                self.setBusy(nil)
                if let failure { self.report(failure) }
                if !copied.isEmpty { done(copied) }
            }
        }
    }

    nonisolated private static func unique(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    // MARK: Changing the device's files

    /// The folder new files go into: a folder or app selected, or the one holding the file selected.
    private func targetFolder(of node: Node?) -> Node? {
        guard let node else { return flat ? current : nil }
        return node.isDirectory ? node : node.parent
    }

    @objc private func newFolder(_ sender: Any?) {
        guard let store, let folder = targetFolder(of: selectedNodes.first), let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Новая папка")
        let field = NSTextField(string: L("Новая папка"))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Создать"))
        alert.addButton(withTitle: L("Отменить"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty, !name.contains("/") else { return }
            store.queue.async {
                let result = Result { try store.with(folder.root) { try $0.makeDirectory(folder.path + "/" + name) } }
                DispatchQueue.main.async {
                    if case .failure(let error) = result { self?.report(error) }
                    self?.refresh(folder)
                    self?.outline.expandItem(folder)
                }
            }
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        let nodes = selectedNodes.filter { !$0.isApp }
        guard let store, !nodes.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = nodes.count == 1 ? L("Удалить «%@» с устройства?", nodes[0].name)
            : L("Удалить с устройства объекты (%@)?", String(nodes.count))
        alert.informativeText = L("Это действие нельзя отменить.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Удалить"))
        alert.addButton(withTitle: L("Отменить"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            store.queue.async {
                var failure: Error?
                for node in nodes {
                    do { try store.with(node.root) { try $0.remove(node.path) } } catch { failure = error }
                }
                DispatchQueue.main.async {
                    if let failure { self?.report(failure) }
                    self?.onDeviceChanged?()
                    for parent in Set(nodes.compactMap { $0.parent.map(ObjectIdentifier.init) }) {
                        if let node = nodes.first(where: { $0.parent.map(ObjectIdentifier.init) == parent })?.parent { self?.refresh(node) }
                    }
                }
            }
        }
    }

    private func upload(_ urls: [URL], into folder: Node) {
        guard let store else { return }
        let total = urls.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        setBusy(L("Копирование на устройство…"))
        store.queue.async {
            let result = Result {
                try store.upload(urls, to: folder.path, root: folder.root) { bytes in
                    if total > 0 {
                        let percent = Int(Double(bytes) / Double(total) * 100)
                        DispatchQueue.main.async { self.setBusy(L("Копирование на устройство… %@ %", String(min(percent, 100)))) }
                    }
                    return true
                }
            }
            DispatchQueue.main.async {
                self.setBusy(nil)
                if case .failure(let error) = result { self.report(error) }
                self.onDeviceChanged?()
                self.refresh(folder)
                self.outline.expandItem(folder)
            }
        }
    }

    nonisolated private static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        var total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        for case let child as URL in enumerator { total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    private func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        let alert = NSAlert()
        alert.messageText = L("Не удалось выполнить действие на устройстве")
        alert.informativeText = String(describing: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let nodes = selectedNodes
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if nodes.contains(where: { !$0.isDirectory }) { add(L("Открыть"), #selector(openSelected(_:))) }
        if !nodes.isEmpty { add(L("Скопировать на Mac…"), #selector(copyToMac(_:))) }
        if targetFolder(of: nodes.first) != nil { add(L("Новая папка"), #selector(newFolder(_:))) }
        if nodes.contains(where: { !$0.isApp }) {
            menu.addItem(.separator())
            add(L("Удалить с устройства…"), #selector(deleteSelected(_:)))
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        add(L("Обновить"), #selector(reloadAll(_:)))
        MenuStyle.decorate(menu)
    }

    @objc private func reloadAll(_ sender: Any?) {
        guard let store else { return }
        // Flat: the folder shown, read again
        if flat, let current { return refresh(current) }
        show(store.udid)
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? Node else { return nil }
        return promise(for: node)
    }

    /// A file or folder dragged out: copied from the device where it's dropped.
    private func promise(for node: Node) -> NSFilePromiseProvider? {
        guard !node.isApp else { return nil }
        let type = node.isDirectory ? UTType.folder : UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = node
        return provider
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        MainActor.assumeIsolated { (filePromiseProvider.userInfo as? Node)?.name ?? "file" }
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        let job: (DeviceFileStore, Node)? = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let node = filePromiseProvider.userInfo as? Node, let store = self.store else { return nil }
                self.setBusy(L("Копирование «%@»…", node.name))
                return (store, node)
            }
        }
        guard let (store, node) = job else { return completionHandler(CocoaError(.fileNoSuchFile)) }
        store.queue.async {
            let result = Result { try store.download(node.root, node.path, isDirectory: node.isDirectory, to: url) { _ in true } }
            DispatchQueue.main.async { self.setBusy(nil) }
            if case .failure(let error) = result { completionHandler(error) } else { completionHandler(nil) }
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.promiseQueue
    }

    nonisolated private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView !== outline, let folder = targetFolder(of: item as? Node),
              !FileDrop.urls(info).isEmpty else { return [] }
        // Flat: onto a folder's row, or anywhere else into the folder shown
        outlineView.setDropItem(folder === current ? nil : folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = targetFolder(of: item as? Node) else { return false }
        let urls = FileDrop.urls(info)
        guard !urls.isEmpty else { return false }
        upload(urls, into: folder)
        return true
    }

    // MARK: Quick Look

    private var previewItems: [DevicePreview.Item] {
        selectedNodes.filter { !$0.isDirectory }.map { DevicePreview.Item(root: $0.root, path: $0.path, size: $0.size) }
    }

    private func quickLook() {
        guard let store else { return }
        preview.keyView = focusView
        preview.toggle(previewItems, store: store)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { preview.selectionChanged(previewItems) }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { preview.selectionChanged(previewItems) }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { preview.selectionChanged(previewItems) }

    // MARK: Icons (flat mode)

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: DeviceIconItem.identifier, for: indexPath)
        if let icon = item as? DeviceIconItem, indexPath.item < shown.count {
            let node = shown[indexPath.item]
            icon.configure(name: node.name, icon: self.icon(for: node))
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        indexPaths.allSatisfy { $0.item < shown.count && !shown[$0.item].isApp }
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        indexPath.item < shown.count ? promise(for: shown[indexPath.item]) : nil
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard draggingInfo.draggingSource as? NSCollectionView !== grid, !FileDrop.urls(draggingInfo).isEmpty,
              dropFolder(at: proposedIndexPath.pointee as IndexPath, operation: dropOperation.pointee) != nil else { return [] }
        return .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = FileDrop.urls(draggingInfo)
        guard !urls.isEmpty, let folder = dropFolder(at: indexPath, operation: dropOperation) else { return false }
        upload(urls, into: folder)
        return true
    }

    /// Onto a folder's icon: that folder; anywhere else: the folder shown (none at the apps' level,
    /// except onto an app).
    private func dropFolder(at indexPath: IndexPath, operation: NSCollectionView.DropOperation) -> Node? {
        if operation == .on, indexPath.item < shown.count, shown[indexPath.item].isDirectory { return shown[indexPath.item] }
        return current
    }
}

/// Flat mode's icons: double-click and ↩ open, ⌫ deletes, Space shows Quick Look, a right click
/// selects what it's on.
private final class DeviceIconGrid: NSCollectionView, DevicePreviewHost {
    var onOpen: ((Int) -> Void)?
    var onDelete: (() -> Void)?
    var onSpace: (() -> Void)?
    weak var preview: DevicePreview?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewAccepts() }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { previewBegin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { previewEnd(panel) }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let index = indexPathForItem(at: point) { onOpen?(index.item) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: if let index = selectionIndexPaths.sorted().first { onOpen?(index.item) }
        case 51, 117: onDelete?()
        case 49: onSpace?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let index = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(index) { selectionIndexPaths = [index] }
        } else {
            selectionIndexPaths = []
        }
        return super.menu(for: event)
    }
}

/// An icon with its name under it (two lines at most), a rounded highlight when selected.
private final class DeviceIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("deviceIcon")
    private let picture = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let highlight = NSView()

    override func loadView() {
        let root = NSView()
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        picture.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.font = .systemFont(ofSize: 12)
        for view in [highlight, picture, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            picture.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            picture.widthAnchor.constraint(equalToConstant: 56),
            picture.heightAnchor.constraint(equalToConstant: 56),
            label.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            highlight.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            highlight.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            highlight.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            highlight.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
        ])
        view = root
    }

    func configure(name: String, icon: NSImage) {
        picture.image = icon
        label.stringValue = name
        view.toolTip = name
    }

    override var isSelected: Bool {
        didSet { highlight.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil }
    }
}

/// ⌫ deletes and Space shows Quick Look, as in the file list.
private final class DeviceOutlineView: NSOutlineView, DevicePreviewHost {
    var onDelete: (() -> Void)?
    var onSpace: (() -> Void)?
    weak var preview: DevicePreview?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()
        case 49: onSpace?()
        default: super.keyDown(with: event)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewAccepts() }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { previewBegin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { previewEnd(panel) }
}

/// Over the list: shows, never catches clicks.
final class DeviceOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
