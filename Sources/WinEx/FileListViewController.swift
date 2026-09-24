import AppKit
import Quartz
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
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate, NSMenuItemValidation,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {

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
        NotificationCenter.default.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil, queue: .main) { [weak self] _ in
            // Catch up on changes that arrived during a rename (after the field has resigned)
            DispatchQueue.main.async {
                guard let self, self.reloadAfterEditing else { return }
                self.reload()
            }
        }
        NotificationCenter.default.addObserver(forName: .folderViewDefaultsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showFolderView() }
        }
        NotificationCenter.default.addObserver(forName: .fileTagsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: FileClipboard.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCutAppearance() }
        }
    }

    private func setUpTable(menu: NSMenu) {
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("name", "Имя", 320), ("date", "Дата изменения", 150), ("type", "Тип", 160), ("size", "Размер", 90),
            ("tags", "Теги", 70),
        ]
        for column in columns {
            let tableColumn = NSTableColumn(identifier: .init(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            if column.id != "tags" { tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true) }
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
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic, .delete], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.onOpen = { [weak self] in self?.openSelected(nil) }
        tableView.onGoUp = { [weak self] in
            guard let self else { return }
            self.delegate?.fileListGoUp(self)
        }
        tableView.onZoom = { [weak self] step in self?.zoom(step) }
        tableView.onRename = { [weak self] in self?.renameSelected(nil) }
        tableView.onQuickLook = { [weak self] in if let self { QuickLook.toggle(for: self) } }

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
        collectionView.onRename = { [weak self] in self?.renameSelected(nil) }
        collectionView.onQuickLook = { [weak self] in if let self { QuickLook.toggle(for: self) } }
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

        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.dropTarget = { [weak self] point in
            guard let self, let directory = self.directory else { return nil }
            if let index = self.collectionView.indexPathForItem(at: point)?.item, self.items[index].isFolder {
                return (self.items[index].url, index)
            }
            return (directory, nil)
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
        // Keep the keyboard in the visible view (the hidden one may hold focus after a folder's own view kicks in)
        let hiddenHasFocus = view.window?.firstResponder === focusView(for: viewMode == .details ? .largeIcons : .details)
        if hadFocus || hiddenHasFocus { view.window?.makeFirstResponder(focusView) }
        if let window = view.window, window.initialFirstResponder === tableView || window.initialFirstResponder === collectionView {
            window.initialFirstResponder = focusView
        }

        // A view picked by the user sticks to this folder; restoring a folder's own view saves nothing
        if !isRestoringFolderView, let directory { ViewMode.remember(viewMode, forFolder: directory) }
        delegate?.fileList(self, didChangeViewMode: viewMode)
    }

    private func focusView(for mode: ViewMode) -> NSView {
        mode == .details ? tableView : collectionView
    }

    private var isRestoringFolderView = false

    /// Switches to the view remembered for the current folder.
    private func showFolderView() {
        guard let directory else { return }
        let mode = ViewMode.forFolder(directory)
        guard mode != viewMode else { return }
        isRestoringFolderView = true
        viewMode = mode
        isRestoringFolderView = false
    }

    func applyViewModeToAllFolders() {
        ViewMode.applyToAllFolders(viewMode)
    }

    /// ⌘+wheel / pinch: step through `ViewMode.zoomOrder`.
    private func zoom(_ step: Int) {
        let order = ViewMode.zoomOrder
        let current = order.firstIndex(of: viewMode) ?? order.firstIndex(of: .mediumIcons)!
        viewMode = order[min(max(current + step, 0), order.count - 1)]
    }

    // MARK: - Loading

    func load(_ url: URL, select: [URL]) {
        stopTagQuery()
        if let tag = ExplorerTab.tagName(of: url) {
            // A tag location: every file with the tag, found by Spotlight (updates live)
            directory = nil
            watcher = nil
            startTagQuery(tag)
            refilter(keepSelection: false)
            return
        }
        directory = url
        watcher = DirectoryWatcher(url: url) { [weak self] in self?.reload() }
        readDirectory()
        refilter(keepSelection: false)
        showFolderView()
        // Compare resolved paths: /tmp/x and /private/tmp/x are the same item
        let paths = Set(select.map { $0.resolvingSymlinksInPath().path })
        let indexes = IndexSet(items.indices.filter { paths.contains(items[$0].url.resolvingSymlinksInPath().path) })
        setSelection(indexes, scrollTo: indexes.first ?? 0)
    }

    /// Re-reads the current folder, keeping the selection. Postponed while a name is being edited
    /// (a reload would end the edit — e.g. the watcher firing right after "New ▸ …").
    func reload() {
        guard !isEditingName else {
            reloadAfterEditing = true
            return
        }
        reloadAfterEditing = false
        readDirectory()
        refilter(keepSelection: true)
    }

    private var reloadAfterEditing = false

    private var isEditingName: Bool {
        guard let editor = view.window?.firstResponder as? NSTextView, let field = editor.delegate as? NSView else { return false }
        return field.isDescendant(of: focusView)
    }

    // MARK: - Tag locations

    private var tagQuery: NSMetadataQuery?
    private var tagResults: [URL] = []
    private var tagQueryObservers: [NSObjectProtocol] = []

    private func startTagQuery(_ tag: String) {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemUserTags == %@", tag)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        tagQuery = query
        tagResults = []
        allItems = []
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            tagQueryObservers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tagQueryChanged() }
            })
        }
        query.start()
    }

    private func tagQueryChanged() {
        guard let query = tagQuery else { return }
        query.disableUpdates()
        tagResults = (0..<query.resultCount).compactMap { index in
            (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
        }.map { URL(fileURLWithPath: $0) }
        query.enableUpdates()
        reload()
    }

    private func stopTagQuery() {
        tagQuery?.stop()
        tagQuery = nil
        tagQueryObservers.forEach(NotificationCenter.default.removeObserver)
        tagQueryObservers = []
    }

    func stopWatching() {
        stopTagQuery()
        watcher = nil
    }

    private func readDirectory() {
        if tagQuery != nil {
            allItems = tagResults.map(FileItem.init)
            errorMessage = nil
            return
        }
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
        QuickLook.selectionChanged(in: self)
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
        if let index = items.firstIndex(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
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
            // The table selects the whole name once editing starts; narrow it to the name without extension
            // (view-based tables edit in the cell's text field, so use the window's field editor)
            DispatchQueue.main.async { [weak self] in
                (self?.view.window?.firstResponder as? NSTextView)?.setSelectedRange(
                    FileOps.baseNameRange(of: file.name, isFolder: file.isFolder))
            }
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
        if let index = items.firstIndex(where: { [destination.lastPathComponent, url.lastPathComponent].contains($0.url.lastPathComponent) }) {
            setSelection(IndexSet(integer: index), scrollTo: index)
        }
    }

    @objc func cut(_ sender: Any?) {
        FileClipboard.shared.cut(targetURLs)
    }

    @objc func copy(_ sender: Any?) {
        FileClipboard.shared.copy(targetURLs)
    }

    @objc func paste(_ sender: Any?) {
        guard let directory else { return }
        FileClipboard.shared.paste(into: directory)
    }

    /// Dims cut items (and un-dims them when the cut is cancelled) without reloading.
    private func updateCutAppearance() {
        let clipboard = FileClipboard.shared
        if viewMode == .details {
            let visible = tableView.rows(in: tableView.visibleRect)
            for row in visible.lowerBound..<visible.upperBound where items.indices.contains(row) {
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
                cell?.imageView?.alphaValue = clipboard.isCut(items[row].url) ? Self.cutAlpha : 1
            }
        } else {
            for indexPath in collectionView.indexPathsForVisibleItems() where items.indices.contains(indexPath.item) {
                (collectionView.item(at: indexPath) as? FileGridItem)?.setCut(clipboard.isCut(items[indexPath.item].url))
            }
        }
    }

    static let cutAlpha: CGFloat = 0.4

    @objc private func refresh(_ sender: Any?) {
        reload()
    }

    @objc private func quickLook(_ sender: Any?) {
        // A right-clicked item that isn't selected becomes the selection, so the panel shows it
        if clickedIndex >= 0 && !selectedIndexes.contains(clickedIndex) { setSelection(IndexSet(integer: clickedIndex)) }
        QuickLook.toggle(for: self)
    }

    // MARK: - Quick Look (space)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { QuickLook.accepts(self) }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.detach(panel, from: self)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        QuickLook.forward(event, to: focusView, panel: panel)
    }

    /// The panel zooms out of (and back into) the file's icon.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let iconView = iconView(for: item), let window = iconView.window,
              iconView.visibleRect.width > 0 else { return .zero }
        // Where the picture is actually drawn: previews aren't square, and the image view fits them
        // proportionally — handing over the whole square would stretch the zoom animation.
        let drawn = iconView.image.map { DesktopView.aspectFit($0.size, in: iconView.bounds) } ?? iconView.bounds
        return window.convertToScreen(iconView.convert(drawn, to: nil))
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let image = iconView(for: item)?.image else { return nil }
        contentRect?.pointee = NSRect(origin: .zero, size: image.size)
        return image
    }

    private func iconView(for item: QLPreviewItem?) -> NSImageView? {
        guard let url = item?.previewItemURL, let index = items.firstIndex(where: { $0.url.path == url.path }) else { return nil }
        if viewMode == .details {
            return (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSTableCellView)?.imageView
        }
        return collectionView.item(at: IndexPath(item: index, section: 0))?.imageView
    }

    /// ⌘I / ⌥↩ / context menu: the selection, or the folder itself when nothing is selected.
    @objc func showProperties(_ sender: Any?) {
        let urls = targetURLs
        PropertiesWindowController.show(for: urls.isEmpty ? [directory].compactMap { $0 } : urls)
    }

    @objc private func customizeFolder(_ sender: Any?) {
        guard let index = targetRows.first ?? selectedIndexes.first, items.indices.contains(index) else { return }
        let anchor: NSView, rect: NSRect
        if viewMode == .details {
            anchor = tableView
            rect = tableView.rect(ofRow: index)
        } else {
            anchor = collectionView
            rect = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame ?? .zero
        }
        FolderCustomizationController.show(for: items[index].url, relativeTo: rect, of: anchor)
    }

    @objc private func toggleTag(_ sender: NSMenuItem) {
        guard let toggle = sender.representedObject as? FileTags.TagToggle else { return }
        FileTags.toggle(toggle.tag, on: toggle.urls, add: toggle.add)
        NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
    }

    @objc private func sortByKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: tableView.sortDescriptors.first?.ascending ?? true)]
    }

    @objc private func sortOrder(_ sender: NSMenuItem) {
        let key = tableView.sortDescriptors.first?.key ?? "name"
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: sender.tag == 1)]
    }

    /// "Создать ▸ …": creates the item and starts renaming it, like Explorer.
    @objc private func createNewItem(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? NewItemTemplate, let directory else { return }
        do {
            let url = try template.create(in: directory)
            reload()
            // Match by name: the listing may spell the folder differently (/tmp vs /private/tmp)
            if let index = items.firstIndex(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                setSelection(IndexSet(integer: index), scrollTo: index)
                beginRename(at: index)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func applyToAllFolders(_ sender: Any?) {
        applyViewModeToAllFolders()
    }

    @objc private func changeViewMode(_ sender: NSMenuItem) {
        if let mode = ViewMode(rawValue: sender.tag) { viewMode = mode }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(cut(_:)), #selector(copy(_:)), #selector(moveToTrash(_:)), #selector(openSelected(_:)),
             #selector(renameSelected(_:)), #selector(openInNewTab(_:)), #selector(openInNewWindow(_:)):
            return !targetRows.isEmpty
        case #selector(paste(_:)):
            return FileClipboard.shared.canPaste
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
            // Finder's row of tag colors on top
            menu.addItem(TagRowMenuView.menuItem(for: targetURLs))
            menu.addItem(.separator())
            add("Открыть", #selector(openSelected(_:)))
            add("Быстрый просмотр", #selector(quickLook(_:)))
            if let openWith = OpenWithMenu.item(for: targetURLs) { menu.addItem(openWith) }
            if targetRows.contains(where: { items[$0].isFolder }) {
                add("Открыть в новой вкладке", #selector(openInNewTab(_:)))
                add("Открыть в новом окне", #selector(openInNewWindow(_:)))
            }
            menu.addItem(.separator())
            add("Вырезать", #selector(cut(_:)))
            add("Копировать", #selector(copy(_:)))
            add("Копировать путь", #selector(copyPath(_:)))
            menu.addItem(.separator())
            add("Переименовать", #selector(renameSelected(_:)))
            add("Переместить в корзину", #selector(moveToTrash(_:)))
            menu.addItem(.separator())
            menu.addItem(FileTags.menuItem(for: targetURLs, target: self, action: #selector(toggleTag(_:))))
            if targetRows.count == 1, let row = targetRows.first, items[row].isFolder {
                add("Настроить папку…", #selector(customizeFolder(_:)))
            }
            menu.addItem(.separator())
            add("Свойства", #selector(showProperties(_:)))
        } else {
            let viewItem = NSMenuItem(title: "Вид", action: nil, keyEquivalent: "")
            let viewMenu = NSMenu()
            for mode in ViewMode.allCases {
                let item = viewMenu.addItem(withTitle: mode.title, action: #selector(changeViewMode(_:)), keyEquivalent: "")
                item.target = self
                item.tag = mode.rawValue
            }
            viewMenu.addItem(.separator())
            viewMenu.addItem(withTitle: "Применить ко всем папкам", action: #selector(applyToAllFolders(_:)), keyEquivalent: "").target = self
            viewItem.submenu = viewMenu
            menu.addItem(viewItem)

            let sortMenu = NSMenu()
            let current = tableView.sortDescriptors.first
            for (key, title) in [("name", "Имя"), ("date", "Дата изменения"), ("type", "Тип"), ("size", "Размер")] {
                let item = sortMenu.addItem(withTitle: title, action: #selector(sortByKey(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = key
                item.state = (current?.key ?? "name") == key ? .on : .off
            }
            sortMenu.addItem(.separator())
            for (ascending, title) in [(true, "По возрастанию"), (false, "По убыванию")] {
                let item = sortMenu.addItem(withTitle: title, action: #selector(sortOrder(_:)), keyEquivalent: "")
                item.target = self
                item.tag = ascending ? 1 : 0
                item.state = (current?.ascending ?? true) == ascending ? .on : .off
            }
            menu.addItem(withTitle: "Сортировка", action: nil, keyEquivalent: "").submenu = sortMenu
            add("Обновить", #selector(refresh(_:)))
            menu.addItem(.separator())
            add("Вставить", #selector(paste(_:)))
            menu.addItem(.separator())
            menu.addItem(NewItemTemplate.menuItem(target: self, action: #selector(createNewItem(_:))))
            menu.addItem(.separator())
            add("Копировать путь к папке", #selector(copyPath(_:)))
            add("Свойства", #selector(showProperties(_:)))
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

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Onto a folder row: into that folder; anywhere else: into the current folder
        if dropOperation == .on, items.indices.contains(row), items[row].isFolder {
            let operation = FileDrop.operation(for: info, into: items[row].url)
            if operation != [] { return operation }
        }
        guard let directory else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return FileDrop.operation(for: info, into: directory)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if row >= 0, dropOperation == .on, items.indices.contains(row), items[row].isFolder {
            return FileDrop.perform(info, into: items[row].url)
        }
        guard let directory else { return false }
        return FileDrop.perform(info, into: directory)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dropped on the Trash in the Dock
        if operation == .delete {
            FileOps.trash(session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
        }
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
            cell.imageView?.alphaValue = FileClipboard.shared.isCut(item.url) ? Self.cutAlpha : 1
            cell.textField?.stringValue = item.name
        case "date":
            cell.textField?.stringValue = item.modified.map(Self.dateFormatter.string(from:)) ?? ""
        case "type":
            cell.textField?.stringValue = item.typeDescription
        case "size":
            cell.textField?.stringValue = item.sizeDescription ?? ""
        case "tags":
            let dots = FileTags.dots(for: item.tags, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            cell.textField?.attributedStringValue = dots
            cell.textField?.toolTip = item.tags.map(\.name).joined(separator: ", ")
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
        item.setCut(FileClipboard.shared.isCut(file.url))
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
    var onQuickLook: (() -> Void)?
    var onRename: (() -> Void)?
    var onOpen: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onZoom: ((Int) -> Void)?
    private var zoom = ZoomGesture()

    /// Explorer's Details view: dragging from empty space or from the Date/Type/Size columns draws a
    /// selection rectangle; pressing on a name selects it and can drag the file.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let onName = row >= 0 && column(at: point) == 0
        guard !onName, event.clickCount == 1 else { return super.mouseDown(with: event) }

        // On a row: a plain click still selects it (and double-click opens) — only a drag draws the rectangle
        if row >= 0 && !isDragBeginning(from: event) {
            return super.mouseDown(with: event)
        }
        window?.makeFirstResponder(self)
        let additive = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        let base = additive ? selectedRowIndexes : IndexSet()
        selectRowIndexes(base, byExtendingSelection: false)
        RubberBand.track(in: self, from: point) { rect in
            let rows = self.rows(in: rect)
            selectRowIndexes(base.union(IndexSet(integersIn: rows.lowerBound..<rows.upperBound)), byExtendingSelection: false)
        }
    }

    /// Waits for the mouse to either move a few points (a drag) or be released (a click).
    /// Consumed small moves are harmless; a mouse-up is left in the queue for `super`.
    private func isDragBeginning(from event: NSEvent) -> Bool {
        let start = event.locationInWindow
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                         inMode: .eventTracking, dequeue: false) {
            if next.type == .leftMouseUp { return false }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 4 { return true }
            _ = NSApp.nextEvent(matching: .leftMouseDragged, until: nil, inMode: .eventTracking, dequeue: true)
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76:             // Return, Enter: open (Windows) or rename (Finder)
            if Settings.windowsKeys { onOpen?() } else { onRename?() }
        case 51 where Settings.windowsKeys: onGoUp?()   // Backspace
        case 49: onQuickLook?()  // Space
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
