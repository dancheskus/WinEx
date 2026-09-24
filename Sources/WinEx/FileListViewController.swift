import AppKit
import QuickLookThumbnailing

protocol FileListDelegate: AnyObject {
    func fileList(_ list: FileListViewController, open url: URL, in target: FileListViewController.OpenTarget)
    func fileListGoUp(_ list: FileListViewController)
    func fileList(_ list: FileListViewController, didUpdateStatus status: String)
    func fileList(_ list: FileListViewController, didChangeViewMode mode: ViewMode)
}

/// Contents of the current folder. Shows the same items either as a table ("Details")
/// or in a collection view (icons, list, tiles); selection and actions work on both.
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate, NSMenuItemValidation {

    enum OpenTarget { case current, newTab, newWindow }

    weak var delegate: FileListDelegate?
    let tableView = FileTableView()
    let collectionView = FileCollectionView()

    private let tableScrollView = NSScrollView()
    private let gridScrollView = NSScrollView()
    private let flowLayout = LeftAlignedFlowLayout()

    private(set) var directory: URL?
    private var allItems: [FileItem] = []
    private var items: [FileItem] = []
    private var watcher: DirectoryWatcher?
    private var errorMessage: String?
    private let thumbnails = NSCache<NSString, NSImage>()
    private var requestedThumbnails = Set<NSString>()

    var viewMode: ViewMode = .saved {
        didSet { if viewMode != oldValue { applyViewMode(previous: oldValue) } }
    }

    /// The view that currently shows the files and should get keyboard focus.
    var focusView: NSView { viewMode == .details ? tableView : collectionView }

    var filter = "" {
        didSet { if filter != oldValue { refilter(keepSelection: true) } }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - View

    override func loadView() {
        let menu = NSMenu()
        menu.delegate = self
        setUpTable(menu: menu)
        setUpGrid(menu: menu)

        let container = NSView()
        for scrollView in [tableScrollView, gridScrollView] {
            scrollView.autohidesScrollers = true
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        view = container
        applyViewMode(previous: nil)

        NotificationCenter.default.addObserver(forName: .showHiddenChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func setUpTable(menu: NSMenu) {
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("name", "Имя", 320), ("date", "Дата изменения", 150), ("type", "Тип", 160), ("size", "Размер", 90),
        ]
        for column in columns {
            let tableColumn = NSTableColumn(identifier: .init(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            if column.id == "size" { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        tableView.style = .fullWidth
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.menu = menu
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        tableView.onOpen = { [weak self] in self?.openSelected(nil) }
        tableView.onGoUp = { [weak self] in
            guard let self else { return }
            self.delegate?.fileListGoUp(self)
        }
        tableView.onZoom = { [weak self] step in self?.zoom(step) }

        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = true
    }

    private func setUpGrid(menu: NSMenu) {
        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
        collectionView.menu = menu
        collectionView.onOpen = { [weak self] in self?.openSelected(nil) }
        collectionView.onGoUp = { [weak self] in
            guard let self else { return }
            self.delegate?.fileListGoUp(self)
        }
        collectionView.onZoom = { [weak self] step in self?.zoom(step) }
        collectionView.onSelectionChange = { [weak self] in self?.updateStatus() }
        collectionView.itemName = { [weak self] index in self?.items[index].name ?? "" }
        collectionView.draggingItems = { [weak self] indexes in
            guard let self else { return [] }
            return indexes.map { index in
                let file = self.items[index]
                let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
                let frame = self.collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame ?? .zero
                let iconSize = min(self.viewMode.iconSize, 64)
                item.setDraggingFrame(NSRect(x: frame.midX - iconSize / 2, y: frame.midY - iconSize / 2,
                                             width: iconSize, height: iconSize), contents: file.icon)
                return item
            }
        }

        gridScrollView.documentView = collectionView
    }

    // MARK: - View mode

    private func applyViewMode(previous: ViewMode?) {
        let selection = previous.map(selection(in:)) ?? IndexSet()
        let hadFocus = previous.map { focusView(for: $0) === view.window?.firstResponder } ?? false

        let isDetails = viewMode == .details
        tableScrollView.isHidden = !isDetails
        gridScrollView.isHidden = isDetails
        if isDetails {
            tableView.reloadData()
        } else {
            flowLayout.itemSize = viewMode.itemSize
            flowLayout.scrollDirection = viewMode.scrollsHorizontally ? .horizontal : .vertical
            flowLayout.minimumInteritemSpacing = viewMode.isHorizontalItem ? 2 : 6
            flowLayout.minimumLineSpacing = viewMode.isHorizontalItem ? 2 : 6
            flowLayout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            gridScrollView.hasHorizontalScroller = viewMode.scrollsHorizontally
            gridScrollView.hasVerticalScroller = !viewMode.scrollsHorizontally
            flowLayout.invalidateLayout()
            collectionView.reloadData()
        }
        setSelection(selection, scrollTo: selection.first)
        if hadFocus { view.window?.makeFirstResponder(focusView) }

        ViewMode.saved = viewMode
        delegate?.fileList(self, didChangeViewMode: viewMode)
    }

    private func focusView(for mode: ViewMode) -> NSView {
        mode == .details ? tableView : collectionView
    }

    /// ⌘+wheel / pinch: step through `ViewMode.zoomOrder`.
    private func zoom(_ step: Int) {
        let order = ViewMode.zoomOrder
        let current = order.firstIndex(of: viewMode) ?? order.firstIndex(of: .mediumIcons)!
        viewMode = order[min(max(current + step, 0), order.count - 1)]
    }

    // MARK: - Loading

    func load(_ url: URL, select: [URL]) {
        directory = url
        watcher = DirectoryWatcher(url: url) { [weak self] in self?.reload() }
        readDirectory()
        refilter(keepSelection: false)
        let paths = Set(select.map(\.path))
        let indexes = IndexSet(items.indices.filter { paths.contains(items[$0].url.path) })
        setSelection(indexes, scrollTo: indexes.first ?? 0)
    }

    /// Re-reads the current folder, keeping the selection.
    func reload() {
        readDirectory()
        refilter(keepSelection: true)
    }

    func stopWatching() {
        watcher = nil
    }

    private func readDirectory() {
        guard let directory else { return }
        var options: FileManager.DirectoryEnumerationOptions = []
        if !Settings.showHidden { options.insert(.skipsHiddenFiles) }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: FileItem.keys, options: options)
            allItems = urls.map(FileItem.init)
            errorMessage = nil
        } catch {
            allItems = []
            errorMessage = error.localizedDescription
        }
    }

    private func refilter(keepSelection: Bool) {
        let selectedPaths = keepSelection ? Set(selectedURLs.map(\.path)) : []
        let query = filter.trimmingCharacters(in: .whitespaces)
        items = query.isEmpty ? allItems : allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
        sortItems()
        if viewMode == .details { tableView.reloadData() } else { collectionView.reloadData() }
        setSelection(IndexSet(items.indices.filter { selectedPaths.contains(items[$0].url.path) }))
    }

    private func sortItems() {
        let descriptor = tableView.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        let ascending = descriptor.ascending
        items.sort { a, b in
            // Folders always come first, like in Explorer
            if a.isFolder != b.isFolder { return a.isFolder }
            let result: ComparisonResult
            switch descriptor.key {
            case "date": result = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case "type": result = a.typeDescription.localizedStandardCompare(b.typeDescription)
            case "size": result = compare(a.size ?? -1, b.size ?? -1)
            default: result = a.name.localizedStandardCompare(b.name)
            }
            if result == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    private func updateStatus() {
        var status = "\(items.count) \(plural(items.count, "элемент", "элемента", "элементов"))"
        let selected = selectedIndexes.count
        if selected > 0 { status += "    Выбрано: \(selected)" }
        if let errorMessage { status = "Нет доступа: \(errorMessage)" }
        delegate?.fileList(self, didUpdateStatus: status)
    }

    // MARK: - Selection (shared by table and grid)

    private var selectedIndexes: IndexSet { selection(in: viewMode) }

    private func selection(in mode: ViewMode) -> IndexSet {
        mode == .details ? tableView.selectedRowIndexes : collectionView.selectedIndexes
    }

    private func setSelection(_ indexes: IndexSet, scrollTo index: Int? = nil) {
        if viewMode == .details {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            if let index, index < items.count { tableView.scrollRowToVisible(index) }
        } else {
            collectionView.setSelection(indexes, anchor: indexes.first)
            if let index { collectionView.scrollToItem(index) }
        }
        updateStatus()
    }

    private var selectedURLs: [URL] {
        selectedIndexes.compactMap { items.indices.contains($0) ? items[$0].url : nil }
    }

    private var clickedIndex: Int {
        viewMode == .details ? tableView.clickedRow : collectionView.clickedIndex
    }

    /// Items a context-menu action applies to: the clicked item (and the selection, if it contains it).
    private var targetRows: IndexSet {
        let clicked = clickedIndex
        if clicked >= 0 && !selectedIndexes.contains(clicked) { return IndexSet(integer: clicked) }
        return selectedIndexes
    }

    private var targetURLs: [URL] { targetRows.map { items[$0].url } }

    // MARK: - Actions

    @objc private func doubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        openSelected(sender)
    }

    @objc func openSelected(_ sender: Any?) {
        let urls = targetURLs
        guard let first = urls.first else { return }
        delegate?.fileList(self, open: first, in: .current)
        // Additional folders open in background tabs, files in their apps
        for url in urls.dropFirst() {
            delegate?.fileList(self, open: url, in: .newTab)
        }
    }

    @objc private func openInNewTab(_ sender: Any?) {
        targetURLs.forEach { delegate?.fileList(self, open: $0, in: .newTab) }
    }

    @objc private func openInNewWindow(_ sender: Any?) {
        targetURLs.forEach { delegate?.fileList(self, open: $0, in: .newWindow) }
    }

    @objc func copyPath(_ sender: Any?) {
        let urls = targetURLs
        FileOps.copyPaths(urls.isEmpty ? [directory].compactMap { $0 } : urls)
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        FileOps.trash(urls)
    }

    @objc func newFolder(_ sender: Any?) {
        guard let directory else { return }
        let url = FileOps.newFolderURL(in: directory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        reload()
        if let index = items.firstIndex(where: { $0.url.path == url.path }) {
            setSelection(IndexSet(integer: index), scrollTo: index)
            beginRename(at: index)
        }
    }

    @objc func renameSelected(_ sender: Any?) {
        guard let index = targetRows.first else { return }
        beginRename(at: index)
    }

    private func beginRename(at index: Int) {
        let file = items[index]
        if viewMode == .details {
            tableView.editColumn(0, row: index, with: nil, select: true)
            tableView.currentEditor()?.selectedRange = FileOps.baseNameRange(of: file.name, isFolder: file.isFolder)
        } else {
            collectionView.scrollToItem(index)
            collectionView.layoutSubtreeIfNeeded()
            let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? FileGridItem
            item?.beginRename { [weak self] newName in self?.rename(file.url, to: newName) }
        }
    }

    /// Table cells commit renames through their text field's action.
    @objc private func renameEdited(_ sender: NSTextField) {
        let row = tableView.row(for: sender)
        guard items.indices.contains(row) else { return }
        rename(items[row].url, to: sender.stringValue)
    }

    private func rename(_ url: URL, to rawName: String) {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        if !newName.isEmpty, !newName.contains("/"), destination.path != url.path {
            do {
                try FileManager.default.moveItem(at: url, to: destination)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        // Reload either way so a rejected name reverts on screen
        reload()
        if let index = items.firstIndex(where: { $0.url.path == destination.path || $0.url.path == url.path }) {
            setSelection(IndexSet(integer: index), scrollTo: index)
        }
    }

    @objc func copy(_ sender: Any?) {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    @objc func paste(_ sender: Any?) {
        guard let directory else { return }
        let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            for source in urls {
                let destination = FileOps.uniqueDestination(for: source.lastPathComponent, in: directory)
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                } catch {
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
            }
        }
    }

    @objc private func refresh(_ sender: Any?) {
        reload()
    }

    @objc private func changeViewMode(_ sender: NSMenuItem) {
        if let mode = ViewMode(rawValue: sender.tag) { viewMode = mode }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(moveToTrash(_:)), #selector(openSelected(_:)),
             #selector(renameSelected(_:)), #selector(openInNewTab(_:)), #selector(openInNewWindow(_:)):
            return !targetRows.isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        case #selector(changeViewMode(_:)):
            menuItem.state = menuItem.tag == viewMode.rawValue ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if clickedIndex >= 0 {
            add("Открыть", #selector(openSelected(_:)))
            if targetRows.contains(where: { items[$0].isFolder }) {
                add("Открыть в новой вкладке", #selector(openInNewTab(_:)))
                add("Открыть в новом окне", #selector(openInNewWindow(_:)))
            }
            menu.addItem(.separator())
            add("Копировать", #selector(copy(_:)))
            add("Копировать путь", #selector(copyPath(_:)))
            menu.addItem(.separator())
            add("Переименовать", #selector(renameSelected(_:)))
            add("Переместить в корзину", #selector(moveToTrash(_:)))
        } else {
            let viewItem = NSMenuItem(title: "Вид", action: nil, keyEquivalent: "")
            let viewMenu = NSMenu()
            for mode in ViewMode.allCases {
                let item = viewMenu.addItem(withTitle: mode.title, action: #selector(changeViewMode(_:)), keyEquivalent: "")
                item.target = self
                item.tag = mode.rawValue
            }
            viewItem.submenu = viewMenu
            menu.addItem(viewItem)
            menu.addItem(.separator())
            add("Новая папка", #selector(newFolder(_:)))
            add("Вставить", #selector(paste(_:)))
            menu.addItem(.separator())
            add("Копировать путь к папке", #selector(copyPath(_:)))
            add("Обновить", #selector(refresh(_:)))
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        // Menu actions are sent after the menu closes; forget the clicked item afterwards
        DispatchQueue.main.async { [weak self] in self?.collectionView.clearClickedIndex() }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        refilter(keepSelection: true)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        items[row].url as NSURL
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        let cell = tableView.makeView(withIdentifier: .init(column), owner: self) as? NSTableCellView
            ?? makeCell(identifier: column)
        switch column {
        case "name":
            cell.imageView?.image = item.icon
            cell.textField?.stringValue = item.name
        case "date":
            cell.textField?.stringValue = item.modified.map(Self.dateFormatter.string(from:)) ?? ""
        case "type":
            cell.textField?.stringValue = item.typeDescription
        case "size":
            cell.textField?.stringValue = item.sizeDescription ?? ""
        default:
            break
        }
        return cell
    }

    private func makeCell(identifier: String) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init(identifier)
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text

        if identifier == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            text.isEditable = true
            text.target = self
            text.action = #selector(renameEdited(_:))
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.textColor = .secondaryLabelColor
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
            if identifier == "size" { text.alignment = .right }
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == "name" ? items[row].name : nil
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath) as! FileGridItem
        let file = items[indexPath.item]
        item.configure(with: file, mode: viewMode, image: image(for: file))
        return item
    }

    // MARK: - NSCollectionViewDelegate (rubber-band selection)

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateStatus()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateStatus()
    }

    // MARK: - Thumbnails

    /// Big icon modes show previews (photos, documents…) like Explorer; everything else uses the file icon.
    private func image(for file: FileItem) -> NSImage {
        guard viewMode.usesThumbnails, !file.isFolder else { return file.icon }
        let side = viewMode.iconSize
        let key = "\(Int(side))|\(file.url.path)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard !requestedThumbnails.contains(key) else { return file.icon }
        requestedThumbnails.insert(key)

        let request = QLThumbnailGenerator.Request(
            fileAt: file.url, size: CGSize(width: side, height: side),
            scale: view.window?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let path = file.url.path
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnails.setObject(image, forKey: key)
                guard self.viewMode.iconSize == side,
                      let index = self.items.firstIndex(where: { $0.url.path == path }),
                      let item = self.collectionView.item(at: IndexPath(item: index, section: 0)) as? FileGridItem
                else { return }
                item.setImage(image)
            }
        }
        return file.icon
    }
}

/// Explorer-style keys: Return opens, Backspace goes up a level. ⌘+wheel / pinch changes the view.
final class FileTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onZoom: ((Int) -> Void)?
    private var zoom = ZoomGesture()

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: onOpen?()   // Return, Enter
        case 51: onGoUp?()       // Backspace
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        if let step = zoom.step(forScroll: event) { onZoom?(step) }
    }

    override func magnify(with event: NSEvent) {
        if let step = zoom.step(forMagnify: event) { onZoom?(step) }
    }
}
