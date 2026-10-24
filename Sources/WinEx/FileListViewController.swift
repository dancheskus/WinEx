import AppKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

protocol FileListDelegate: AnyObject {
    func fileList(_ list: FileListViewController, open url: URL, in target: FileListViewController.OpenTarget)
    func fileList(_ list: FileListViewController, reveal url: URL)
    /// Shows a package (an app, a bundle) as a folder.
    func fileList(_ list: FileListViewController, browse package: URL)
    func fileListGoUp(_ list: FileListViewController)
    func fileList(_ list: FileListViewController, didUpdateStatus status: String)
    func fileList(_ list: FileListViewController, didChangeViewMode mode: ViewMode)
}

/// Contents of the current folder. Shows the same items either as a table ("Details")
/// or in a collection view (icons, list, tiles); selection and actions work on both.
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate, NSMenuItemValidation,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate, FileMenuActions {

    enum OpenTarget { case current, newTab, newWindow }

    weak var delegate: FileListDelegate?
    let tableView = FileTableView()
    let collectionView = FileCollectionView()

    private let tableScrollView = NSScrollView()
    /// "Этот Mac": drives instead of files.
    private let drivesView = DrivesView()
    /// An iPhone's or iPad's page.
    private lazy var devicePage: DevicePageView = {
        let page = DevicePageView()
        page.isHidden = true
        page.onOpen = { [weak self] url in
            guard let self else { return }
            delegate?.fileList(self, open: url, in: .current)
        }
        page.onStatus = { [weak self] text in
            guard let self, !page.isHidden else { return }
            delegate?.fileList(self, didUpdateStatus: text)
        }
        page.onTabShown = { [weak self] in
            guard let self, !page.isHidden else { return }
            delegate?.fileList(self, didChangeViewMode: viewMode)
        }
        return page
    }()
    /// "Эта папка пуста", "Ничего не найдено", no access to the Trash…
    private let emptyState = EmptyStateView()
    /// Finder's bar above the Trash ("Очистить") and a server ("Подключен: …", "Отключить").
    private let placeBar = PlaceBar()
    private var placeBarHeight = NSLayoutConstraint()
    private let gridScrollView = NSScrollView()
    private let flowLayout = LeftAlignedFlowLayout()

    private(set) var directory: URL? {
        didSet {
            // iCloud's uploads and downloads of the files shown (a bar on each)
            guard directory != oldValue else { return }
            oldValue.map(CloudProgress.shared.unfollow)
            directory.map(CloudProgress.shared.follow)
            isRemoteFolder = directory.flatMap { try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal }.map { !$0 } ?? false
        }
    }

    deinit {
        // (A closed tab or window stops following its folder)
        MainActor.assumeIsolated { directory.map(CloudProgress.shared.unfollow) }
    }
    private var allItems: [FileItem] = []
    private var items: [FileItem] = []
    #if DEBUG
    var debugShownTags: [String: [String]] { Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.tags.map(\.name)) }) }
    var debugShowsFinderLook: Bool { finderLook != nil }
    #endif
    private var watcher: DirectoryWatcher?
    private var tagWatcher: TagChangeWatcher?
    private var errorMessage: String?
    private let observers = Observers()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var requestedThumbnails = Set<NSString>()

    var viewMode: ViewMode = .saved {
        didSet { if viewMode != oldValue { applyViewMode(previous: oldValue) } }
    }

    /// The view that currently shows the files and should get keyboard focus.
    var focusView: NSView { viewMode == .details ? tableView : collectionView }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - View

    override func loadView() {
        let menu = NSMenu()
        menu.delegate = self
        DeviceImport.seed(menu)
        setUpTable(menu: menu)
        setUpGrid(menu: menu)

        let container = NSView()
        tableScrollView.autohidesScrollers = true
        gridScrollView.autohidesScrollers = true
        drivesView.isHidden = true
        emptyState.isHidden = true
        drivesView.onOpen = { [weak self] url in
            guard let self else { return }
            delegate?.fileList(self, open: url, in: .current)
        }
        drivesView.onOpenInNewTab = { [weak self] url in
            guard let self else { return }
            delegate?.fileList(self, open: url, in: .newTab)
        }
        drivesView.onProperties = { PropertiesWindowController.show(for: [$0]) }
        // Finder's bar above the Trash and a server's shares
        placeBar.translatesAutoresizingMaskIntoConstraints = false
        placeBar.isHidden = true
        container.addSubview(placeBar)
        placeBarHeight = placeBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            placeBar.topAnchor.constraint(equalTo: container.topAnchor),
            placeBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            placeBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            placeBarHeight,
        ])
        for scrollView in [tableScrollView, gridScrollView, drivesView, devicePage, emptyState] as [NSView] {
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: placeBar.bottomAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        view = container
        applyViewMode(previous: nil)

        observers.add(.showHiddenChanged) { [weak self] in self?.reload() }
        // A folder shared or no longer shared: «Общий доступ» lists it at once
        observers.add(FolderSharing.didChange) { [weak self] in
            guard let self, location == .shared else { return }
            load(Places.sharedURL, select: selectedURLs)
        }
        observers.add(.extensionsShownChanged) { [weak self] in self?.reload() }
        // Sorted again what's shown (not read again: instant, also on a server)
        // «Папки сверху» changed in another window or tab showing the same folder
        observers.add(.foldersOnTopChanged) { [weak self] in
            guard let self, let directory, ViewMode.sortOrder(for: directory).foldersOnTop != foldersOnTop else { return }
            foldersOnTop.toggle()
            refilter(keepSelection: true)
        }
        // Rows a line taller or shorter
        observers.add(.itemInfoChanged) { [weak self] in self.map { $0.applyViewMode(previous: $0.viewMode) } }
        // Back from System Settings with access granted: try the Trash again
        observers.add(NSApplication.didBecomeActiveNotification) { [weak self] in
            if self?.location == .trash, self?.errorMessage != nil { self?.reload() }
        }
        observers.add(NSControl.textDidEndEditingNotification) { [weak self] in
            // Catch up on changes that arrived during a rename (after the field has resigned)
            DispatchQueue.main.async {
                guard let self, self.reloadAfterEditing else { return }
                self.reload()
            }
        }
        observers.add(.folderViewDefaultsChanged) { [weak self] in self?.showFolderView() }
        observers.add(NetworkBrowser.didChange) { [weak self] in if self?.location == .network { self?.reload() } }
        // A server's list marks which of its shares are mounted
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.add(name, center: NSWorkspace.shared.notificationCenter) { [weak self] in
                if case .server = self?.location { self?.reload() }
            }
        }
        observers.add(.fileTagsChanged) { [weak self] in self?.reload() }
        observers.add(FileClipboard.didChange) { [weak self] in self?.updateCutAppearance() }
    }

    private func setUpTable(menu: NSMenu) {
        // The user's columns, in the user's order and widths ("Папка" appears only in search results)
        let layout = FileColumn.savedLayout
        for column in layout.order {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = layout.widths[column] ?? column.defaultWidth
            tableColumn.minWidth = column == .name ? 120 : 50
            tableColumn.isHidden = column == .folder || layout.hidden.contains(column)
            if column.isSortable { tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true) }
            if column == .size { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        headerMenu.delegate = self
        let header = FileHeaderView()
        header.menu = headerMenu
        tableView.headerView = header
        observers.add(NSTableView.columnDidMoveNotification, object: tableView) { [weak self] in self?.saveColumns() }
        // Widths the user set by dragging a column's edge — not the last column following the window
        observers.add(NSTableView.columnDidResizeNotification, object: tableView) { [weak self] in
            guard let self, self.view.window?.inLiveResize != true,
                  [.leftMouseDragged, .leftMouseUp].contains(NSApp.currentEvent?.type) else { return }
            self.saveColumns()
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        tableView.style = .fullWidth
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = true
        // A bigger or smaller window changes only the last column: «Имя» keeps the width it was given
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.menu = menu
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        tableView.registerForDraggedTypes(FileDrop.types)
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
        collectionView.register(GroupHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: GroupHeaderView.identifier)
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
                // The picture the window shows (a preview, not the file type's icon), over the icon
                // as it's drawn — same size, same proportions
                let image = self.image(for: file)
                let path = self.groups.indexPath(for: index)
                let frame = self.collectionView.layoutAttributesForItem(at: path)?.frame ?? .zero
                var box: NSRect
                if let shown = self.collectionView.item(at: path)?.imageView, shown.superview != nil {
                    box = shown.convert(shown.bounds, to: self.collectionView)
                } else {
                    let side = self.viewMode.iconSize
                    box = NSRect(x: frame.midX - side / 2, y: frame.minY + 4, width: side, height: side)
                }
                let iconFrame = DesktopView.aspectFit(image.size, in: box)
                // With its name, as Finder drags it
                if let cell = self.collectionView.item(at: path)?.view as? GridItemView {
                    let picture = cell.dragPicture(icon: image, iconFrame: cell.convert(iconFrame, from: self.collectionView))
                    item.setDraggingFrame(self.collectionView.convert(picture.frame, from: cell), contents: picture.image)
                } else {
                    item.setDraggingFrame(iconFrame, contents: image)
                }
                return item
            }
        }

        collectionView.registerForDraggedTypes(FileDrop.types)
        collectionView.dropTarget = { [weak self] point in
            guard let self, let directory = self.directory else { return nil }
            if let index = self.collectionView.itemIndex(at: point), self.items[index].isFolder {
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
        tableScrollView.isHidden = !isDetails || !drivesView.isHidden || !devicePage.isHidden
        gridScrollView.isHidden = isDetails || !drivesView.isHidden || !devicePage.isHidden
        if isDetails {
            tableView.reloadData()
        } else {
            // Item info under the names: a line more per row
            var size = viewMode.itemSize
            if showsItemInfo && !viewMode.isHorizontalItem { size.height += 14 }
            flowLayout.itemSize = size
            flowLayout.scrollDirection = viewMode.scrollsHorizontally ? .horizontal : .vertical
            flowLayout.minimumInteritemSpacing = viewMode.isHorizontalItem ? 2 : 0
            flowLayout.minimumLineSpacing = viewMode.isHorizontalItem ? 2 : 0
            flowLayout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            updateGroupHeaders()
            gridScrollView.hasHorizontalScroller = viewMode.scrollsHorizontally
            gridScrollView.hasVerticalScroller = !viewMode.scrollsHorizontally
            flowLayout.invalidateLayout()
            updateFinderLook()
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

    /// «Папки сверху» for the folder shown (each folder's own, off by default).
    private var foldersOnTop = false

    /// «Группировать по» for the folder shown (each folder's own; empty: no groups).
    private var groupBy = ""

    /// Where the groups of `items` start: the table's heading rows, the grid's sections.
    private var groups = FileGroups()

    /// Switches to the view (and the sorting) remembered for the current folder.
    private func showFolderView() {
        guard let directory else { return }
        showSortOrder(ViewMode.sortOrder(for: directory))
        let mode = ViewMode.forFolder(directory)
        guard mode != viewMode else { return }
        isRestoringFolderView = true
        viewMode = mode
        isRestoringFolderView = false
    }

    private func showSortOrder(_ order: FileItem.SortOrder) {
        foldersOnTop = order.foldersOnTop
        groupBy = order.group
        if tableView.sortDescriptors.first?.key != order.key || tableView.sortDescriptors.first?.ascending != order.ascending {
            isRestoringFolderView = true
            tableView.sortDescriptors = [NSSortDescriptor(key: order.key, ascending: order.ascending)]
            isRestoringFolderView = false
        }
    }

    /// «Показывать свойства» for the folder shown (its own choice, else the default).
    var showsItemInfo: Bool { directory.map(ViewMode.showsItemInfo(in:)) ?? Settings.showItemInfo }

    @objc func toggleItemInfo(_ sender: Any?) {
        guard let directory else { return }
        ViewMode.setShowsItemInfo(!showsItemInfo, in: directory)
    }

    /// After saying what it does: this view for every folder, the views chosen for single folders forgotten.
    func applyViewModeToAllFolders() {
        let alert = NSAlert()
        alert.messageText = L("Применить вид этой папки ко всем папкам?")
        alert.informativeText = L("Все папки будут открываться в виде «%@»", viewMode.title) + ", "
            + (showsItemInfo ? L("со свойствами под названиями.") : L("без свойств под названиями."))
        alert.addButton(withTitle: L("Применить ко всем"))
        alert.addButton(withTitle: L("Отменить"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ViewMode.applyToAllFolders(viewMode, itemInfo: showsItemInfo)
    }

    /// ⌘+wheel / pinch: step through `ViewMode.zoomOrder`.
    private func zoom(_ step: Int) {
        let order = ViewMode.zoomOrder
        let current = order.firstIndex(of: viewMode) ?? order.firstIndex(of: .mediumIcons)!
        viewMode = order[min(max(current + step, 0), order.count - 1)]
    }

    // MARK: - Loading

    func load(_ url: URL, select: [URL]) {
        stopSearch()
        searchNote = nil
        showDrives(false)
        showDevice(nil)
        loader.cancel()
        reloadCompletions = []
        let location = Location(url)
        self.location = location
        switch location {
        case .network:
            // "Сеть": servers found by Bonjour; double-click mounts one
            directory = nil
            watcher = nil; tagWatcher = nil
            NetworkBrowser.shared.start()
            showNetworkServers()
            refilter(keepSelection: false)
            return
        case .server(let server):
            // A server: its shares, read in the background; double-click mounts one
            directory = nil
            watcher = nil; tagWatcher = nil
            allItems = []
            showServerShares(server, login: .allowed, select: select)
            return
        case .tag(let tag):
            // A tag location: every file with the tag, found by Spotlight (updates live)
            startSearch(FileSearch(predicate: NSPredicate(format: "kMDItemUserTags == %@", tag), scope: nil))
            return
        case .computer:
            startSearch(nil)
            showDrives(true)
            return
        case .device(let udid, let path):
            startSearch(nil)
            showDevice(udid, path: path)
            return
        case .recents:
            // Like Finder's Recents: the last opened first (until another order is picked here)
            showSortOrder(FileItem.SortOrder(key: "opened", ascending: false))
            startSearch(FileSearch.recents())
            return
        case .shared:
            startSearch(FileSearch.shared())
            return
        case .search(let request):
            guard !request.isTooShort else {
                startSearch(nil)
                errorMessage = nil
                searchNote = L("Введите хотя бы 2 символа для поиска на всём Mac")
                refilter(keepSelection: false)
                return
            }
            startSearch(FileSearch(request))
            return
        case .folder, .trash:
            break
        }
        directory = url
        watcher = DirectoryWatcher(url: url) { [weak self] in self?.reload() }
        tagWatcher = TagChangeWatcher(url: url) { [weak self] in self?.reload() }
        updateFolderColumn()
        showFolderView()
        // Compare resolved paths: /tmp/x and /private/tmp/x are the same item
        let paths = Set(select.map { $0.resolvingSymlinksInPath().path })
        let (showHidden, order) = (Settings.showHidden, sortOrder)
        loader.read({ FolderLoader.contents(of: url, showHidden: showHidden, sortedBy: order) }) { [weak self] listing in
            guard let self else { return }
            apply(listing)
            refilter(keepSelection: false)
            let indexes = paths.isEmpty ? IndexSet()
                : IndexSet(items.indices.filter { paths.contains(self.items[$0].url.resolvingSymlinksInPath().path) })
            setSelection(indexes, scrollTo: indexes.first ?? 0)
        }
        // A slow folder: show it empty (not the previous folder's files) until the listing arrives
        if loader.isWaiting {
            allItems = []
            errorMessage = nil
            refilter(keepSelection: false)
        }
    }

    /// Re-reads the current folder in the background, keeping the selection; `then` runs once the
    /// new listing is on screen. Postponed while a name is being edited (a reload would end the
    /// edit — e.g. the watcher firing right after "New ▸ …").
    func reload(then completion: (() -> Void)? = nil) {
        guard !isEditingName else {
            reloadAfterEditing = true
            return
        }
        reloadAfterEditing = false
        if let completion { reloadCompletions.append(completion) }
        if location == .network {
            showNetworkServers()
            finishReload()
            return
        }
        if case .server(let server) = location {
            showServerShares(server, login: .silent, then: { [weak self] in self?.finishReload() })
            return
        }
        let produce: FolderLoader.Produce
        if search != nil {
            let urls = searchState.results
            let order = sortOrder
            produce = { FolderLoader.Listing(items: FileItem.sorted(urls.map(FileItem.init), by: order), order: order) }
        } else if let directory {
            let (showHidden, order) = (Settings.showHidden, sortOrder)
            produce = { FolderLoader.contents(of: directory, showHidden: showHidden, sortedBy: order) }
        } else {
            return
        }
        loader.refresh(produce) { [weak self] listing in
            self?.apply(listing)
            self?.finishReload()
        }
    }

    private func finishReload() {
        refilter(keepSelection: true)
        selectPendingItem()
        let completions = reloadCompletions
        reloadCompletions = []
        completions.forEach { $0() }
    }

    private let loader = FolderLoader()
    private var reloadCompletions: [() -> Void] = []

    /// An item to select once the list is reloaded (the renamed file: the reload that shows its
    /// new name can be postponed until the name field has let go).
    private var pendingSelectionName: String?
    /// The same for several items renamed together (their paths).
    private var pendingSelection: Set<String> = []

    private func selectPendingItem() {
        if !pendingSelection.isEmpty {
            let indexes = IndexSet(items.indices.filter { pendingSelection.contains(items[$0].url.standardizedFileURL.path) })
            guard let first = indexes.first else { return }
            pendingSelection = []
            return setSelection(indexes, scrollTo: first)
        }
        guard let name = pendingSelectionName,
              let index = items.firstIndex(where: { $0.url.lastPathComponent == name }) else { return }
        pendingSelectionName = nil
        setSelection(IndexSet(integer: index), scrollTo: index)
    }

    private var reloadAfterEditing = false

    private var isEditingName: Bool {
        guard let editor = view.window?.firstResponder as? NSTextView, let field = editor.delegate as? NSView else { return false }
        return field.isDescendant(of: focusView)
    }

    // MARK: - Tags and search results

    /// Spotlight results shown instead of a folder (a tag or a search), live.
    private var search: FileSearch?
    private var searchState = FileSearch.State()
    /// Shown in the status bar instead of the item count (e.g. "type at least 2 characters").
    private var searchNote: String?

    private func startSearch(_ newSearch: FileSearch?) {
        directory = nil
        watcher = nil; tagWatcher = nil
        allItems = []
        allItemsOrder = nil
        errorMessage = nil
        search = newSearch
        searchState = FileSearch.State()
        updateFolderColumn()
        refilter(keepSelection: false)
        guard let newSearch else { return }
        newSearch.onChange = { [weak self] state in
            self?.searchState = state
            self?.reload()
        }
        newSearch.start()
    }

    private func stopSearch() {
        search?.stop()
        search = nil
        searchState = FileSearch.State()
    }

    /// Results come from many folders: show where each one is.
    private func updateFolderColumn() {
        // (Its own rule: shown in search results only; not a user choice)
        // Showing a column makes the table ask for its rows at once: it must know the current ones
        tableView.reloadData()
        tableView.tableColumn(withIdentifier: .init("folder"))?.isHidden = search == nil
    }

    func stopWatching() {
        stopSearch()
        loader.cancel()
        watcher = nil; tagWatcher = nil
    }

    /// What is shown: a folder, the Trash, a tag or the network.
    private(set) var location: Location?
    /// The network or a server: a list of servers or shares, not files.
    private var showingNetwork: Bool {
        if case .server = location { return true }
        return location == .network
    }

    private func showNetworkServers() {
        // Finder's server picture
        let icon = NSWorkspace.shared.icon(for: UTType("com.apple.xserve") ?? .volume)
        allItems = NetworkBrowser.shared.serversWithConnected.map { FileItem(virtual: $0.name, url: $0.url, icon: icon, kind: L("Сервер (%@)", $0.url.scheme?.uppercased() ?? "")) }
        allItemsOrder = nil
        errorMessage = nil
    }

    /// The shown server's shares (the last list while logging in again).
    private var serverListing: ServerShares.Listing?

    /// Logged in to the shown server, as whom: the bar says so and offers what Finder's does.
    private enum ServerLogin { case connecting, connected(user: String?), failed }
    private var serverLogin = ServerLogin.connecting

    /// A server's shares: the last list at once, then the fresh one. Every item is the share's
    /// address, so opening it mounts it if needed.
    private func showServerShares(_ server: URL, login: ServerShares.Login, select: [URL] = [], then completion: (() -> Void)? = nil) {
        // Opening the server: the last list at once, "Подключение…" until logged in. «Подключиться
        // как…» changes nothing until its login window is answered
        let fresh = completion == nil && login != .ask
        if fresh {
            serverListing = ServerShares.cached(server)
            serverLogin = .connecting
            showShares()
            refilter(keepSelection: false)
        }
        ServerShares.list(server, login: login) { [weak self] listing in
            guard let self, self.location == .server(server) else { return }
            if login == .ask, listing == nil { return }  // cancelled: as it was
            serverLogin = listing.map { .connected(user: $0.user) } ?? .failed
            serverListing = listing
            showShares()
            if let completion { return completion() }
            refilter(keepSelection: true)
            // Up from a share's folder: that share selected
            let volumes = Set(select.map(\.standardizedFileURL.path))
            let names = Set(listing?.shares.filter { $0.volume.map { volumes.contains($0.standardizedFileURL.path) } == true }.map(\.name) ?? [])
            let indexes = IndexSet(items.indices.filter { names.contains(self.items[$0].name) })
            if !indexes.isEmpty { setSelection(indexes, scrollTo: indexes.first ?? 0) }
        }
    }

    private func showShares() {
        // Finder's shared-folder picture, mounted or not
        let icon = NSWorkspace.shared.icon(for: UTType("public.file-sharepoint") ?? .folder)
        allItems = (serverListing?.shares ?? []).map { share in
            FileItem(virtual: share.name, url: share.url, icon: icon, kind: share.volume == nil ? L("Общая папка") : L("Подключена"))
        }
        allItemsOrder = nil
        errorMessage = nil
    }

    /// The bar above the list: the Trash's "Очистить"; a server's login and "Отключить".
    private func updatePlaceBar() {
        var shown = true
        switch location {
        case .trash:
            placeBar.show(L("Корзина"), emphasized: true, buttons: [
                PlaceBar.Button(title: L("Очистить"), toolTip: L("Удалить навсегда всё, что лежит в Корзине"),
                                enabled: errorMessage == nil && !allItems.isEmpty) { [weak self] in self?.emptyTrash(nil) },
            ])
        case .server(let server):
            let connectAs = PlaceBar.Button(title: L("Подключиться как…"), toolTip: nil, enabled: true) { [weak self] in
                self?.showServerShares(server, login: .ask)
            }
            switch serverLogin {
            case .connecting:
                placeBar.show(L("Подключение…"), emphasized: false, buttons: [])
            case .failed:
                placeBar.show(L("Не подключен"), emphasized: false, buttons: [connectAs])
            case .connected(let user):
                // As in Finder: connected means "Отключить" (another login is offered once disconnected)
                placeBar.show(user.map { L("Подключен: %@", $0) } ?? L("Подключен как гость"), emphasized: false, buttons: [
                    PlaceBar.Button(title: L("Отключить"), toolTip: L("Извлечь все подключённые папки «%@» и выйти из него", location?.title ?? ""), enabled: true) { [weak self] in
                        self?.disconnect(from: server)
                    },
                ])
            }
        default:
            shown = false
        }
        placeBar.isHidden = !shown
        placeBarHeight.constant = shown ? PlaceBar.height : 0
    }

    private func apply(_ listing: FolderLoader.Listing) {
        allItems = listing.items
        allItemsOrder = listing.order
        if let folder = listing.lookFolder { folderLook = (folder, listing.look) }
        errorMessage = listing.error.map { error in
            location == .trash
                ? L("Корзина откроется, когда WinEx получит «Полный доступ к диску»")
                : error.localizedDescription
        }
    }

    /// The order `allItems` is sorted in (listings arrive sorted from the background).
    private var allItemsOrder: FileItem.SortOrder?

    // MARK: Finder-styled folders

    /// A folder styled for Finder (a disk image's window): its background, and icons of its size
    /// where Finder puts them — in the icon views.
    private var finderLook: FinderLook?
    /// The styling read with the last listing of a folder (`FolderLoader.Listing.look`).
    private var folderLook: (folder: URL, look: FinderLook?)?
    private let lookLayout = FinderLookLayout()
    private let lookBackground = FinderLookBackground()

    private func updateFinderLook() {
        // (Groups: Finder's own arrangement doesn't apply, as in Finder)
        finderLook = search == nil && !groups.isGrouped && folderLook?.folder == directory ? folderLook?.look : nil
        guard let look = finderLook, viewMode != .details, !viewMode.isHorizontalItem else {
            if collectionView.collectionViewLayout !== flowLayout { collectionView.collectionViewLayout = flowLayout }
            collectionView.backgroundView = nil
            return
        }
        lookLayout.look = look
        lookLayout.names = items.map(\.url.lastPathComponent)
        lookLayout.itemSize = NSSize(width: max(look.iconSize + 44, 112), height: look.iconSize + 10 + 7 + 30 + (showsItemInfo ? 14 : 0))
        lookLayout.iconTop = 10
        if collectionView.collectionViewLayout !== lookLayout { collectionView.collectionViewLayout = lookLayout }
        lookLayout.invalidateLayout()
        lookBackground.look = look
        collectionView.backgroundView = lookBackground
        collectionView.backgroundViewScrollsWithContent = true
    }

    private func refilter(keepSelection: Bool) {
        let selectedPaths = keepSelection ? Set(selectedURLs.map(\.path)) : []
        let order = sortOrder
        if allItemsOrder != order {
            FileItem.sort(&allItems, by: order)
            allItemsOrder = order
        }
        items = allItems
        groups = FileGroups(items, by: groupBy)
        collectionView.groups = groups
        updateGroupHeaders()
        updateFinderLook()
        if viewMode == .details { tableView.reloadData() } else { collectionView.reloadData() }
        setSelection(IndexSet(items.indices.filter { selectedPaths.contains(items[$0].url.path) }))
    }

    private var sortOrder: FileItem.SortOrder {
        let descriptor = tableView.sortDescriptors.first
        return FileItem.SortOrder(key: descriptor?.key ?? "name", ascending: descriptor?.ascending ?? true,
                                  foldersOnTop: foldersOnTop, group: groupBy)
    }

    /// Showing an iPhone's or iPad's page: its «Файлы» as icons or as the tree (nil: not a device).
    var deviceFilesAsIcons: Bool? { devicePage.isHidden ? nil : devicePage.filesAsIcons }

    func setDeviceFilesAsIcons(_ flat: Bool) { devicePage.setFilesAsIcons(flat) }

    /// The device's page is on a tab the view buttons don't act on («Основные», «Фото»).
    var deviceTabWithoutViews: Bool { !devicePage.isHidden && !devicePage.showsFiles }

    /// A device's page in place of the files (nil: hidden again).
    private func showDevice(_ udid: String?, path: String = "") {
        guard udid != nil || !devicePage.isHidden else { return }
        devicePage.isHidden = udid == nil
        tableScrollView.isHidden = udid != nil || viewMode != .details || !drivesView.isHidden
        gridScrollView.isHidden = udid != nil || viewMode == .details || !drivesView.isHidden
        guard let udid else { return }
        emptyState.isHidden = true
        devicePage.show(udid, path: path)
    }

    private func showDrives(_ show: Bool) {
        drivesView.isHidden = !show
        tableScrollView.isHidden = show || viewMode != .details
        gridScrollView.isHidden = show || viewMode == .details
        guard show else { return }
        emptyState.isHidden = true
        drivesView.reload()
        view.window?.makeFirstResponder(drivesView)
        delegate?.fileList(self, didUpdateStatus: "\(drivesView.driveCount) \(plural(drivesView.driveCount, L("диск"), L("диска"), L("дисков")))")
    }

    // MARK: Size of the selection

    /// Bytes of the selected items; folders (and packages) are added once counted in the background.
    private var selectionSize: (urls: [URL], bytes: Int64, counting: Bool)?
    private var sizeJob: CancelFlag?

    private func selectionSizeText() -> String? {
        let selected = selectedIndexes.map { items[$0] }.filter { $0.url.isFileURL }
        guard !selected.isEmpty else { return nil }
        let urls = selected.map(\.url)
        if selectionSize?.urls != urls { countSelection(selected) }
        guard let size = selectionSize else { return nil }
        let bytes = ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)
        if !size.counting { return bytes }
        return size.bytes > 0 ? L("%@ + папки…", bytes) : L("размер считается…")
    }

    /// Files are summed right away; folders are walked at background priority once the selection
    /// settles, and the walk stops as soon as the selection changes.
    private func countSelection(_ selected: [FileItem]) {
        sizeJob?.cancel()
        sizeJob = nil
        let urls = selected.map(\.url)
        let fileBytes = selected.compactMap(\.size).reduce(Int64(0)) { $0 + Int64($1) }
        let folders = selected.filter { $0.size == nil }.map(\.url)
        selectionSize = (urls, fileBytes, !folders.isEmpty)
        guard !folders.isEmpty else { return }
        let flag = CancelFlag()
        sizeJob = flag
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !flag.isCancelled else { return }
            DispatchQueue.global(qos: .utility).async {
                var total = fileBytes
                for folder in folders {
                    guard !flag.isCancelled else { return }
                    total += FileOperation.size(of: folder, cancel: flag).bytes
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in
                        guard let self, !flag.isCancelled, self.selectionSize?.urls == urls else { return }
                        self.selectionSize = (urls, total, false)
                        self.updateStatus()
                    }
                }
            }
        }
    }

    /// A message instead of an empty list: why it's empty and what to do about it.
    private func updateEmptyState() {
        updatePlaceBar()
        guard items.isEmpty, drivesView.isHidden, devicePage.isHidden else { return emptyState.isHidden = true }
        if location == .trash, errorMessage != nil {
            emptyState.show(L("Нет доступа к Корзине"),
                            detail: L("macOS показывает Корзину только программам с «Полным доступом к диску». Включите WinEx в настройках и нажмите «Закрыть и открыть снова»."),
                            button: L("Открыть настройки «Полный доступ к диску»…")) { Places.openFullDiskAccessSettings() }
        } else if let errorMessage {
            emptyState.show(L("Нет доступа к папке"), detail: errorMessage)
        } else if let searchNote {
            emptyState.show(searchNote)
        } else if case .search = location {
            if searchState.gathering || searchState.walking { emptyState.isHidden = true } else { emptyState.show(L("Ничего не найдено")) }
        } else if location == .network {
            emptyState.show(L("Серверы не найдены"), detail: L("Подключиться к серверу по адресу — ⌘K."))
        } else if case .server(let server) = location {
            if case .failed = serverLogin {
                emptyState.show(L("Нет списка общих папок"),
                                detail: L("Чтобы увидеть папки «%@», подключитесь к нему.", Places.serverName(of: server) ?? ""),
                                button: L("Подключиться как…")) { [weak self] in self?.showServerShares(server, login: .ask) }
            } else {
                emptyState.isHidden = true
            }
        } else if case .tag = location {
            emptyState.isHidden = !(search.map { !$0.state.gathering } ?? true)
            if !emptyState.isHidden { emptyState.show(L("Нет файлов с этим тегом")) }
        } else if location == .recents || location == .shared {
            emptyState.isHidden = !(search.map { !$0.state.gathering } ?? true)
            if !emptyState.isHidden {
                if location == .recents {
                    emptyState.show(L("Нет недавних файлов"), detail: L("Здесь появятся файлы, открытые за последние 30 дней."))
                } else {
                    emptyState.show(L("Нет объектов в общем доступе"),
                                    detail: L("Здесь появятся папки, открытые для общего доступа по сети, и файлы iCloud Drive, которыми вы поделились или которыми поделились с вами."))
                }
            }
        } else if !loader.isWaiting {
            emptyState.show(location == .trash ? L("Корзина пуста") : L("Эта папка пуста"))
        } else {
            emptyState.isHidden = true
        }
    }

    private func updateStatus() {
        guard drivesView.isHidden, devicePage.isHidden else { return }  // "Этот Mac" keeps its own status
        updateEmptyState()
        var status = "\(items.count) \(plural(items.count, L("элемент"), L("элемента"), L("элементов")))"
        if search != nil, case .search = location {
            status = L("Найдено: %@", items.count)
            if searchState.truncated { status += L(" (показаны самые подходящие)") }
            if searchState.gathering || searchState.walking { status += L("    Поиск…") }
        }
        if let searchNote { status = searchNote }
        let selected = selectedIndexes.count
        if selected > 0 {
            status += L("    Выбрано: %@", selected)
            if let size = selectionSizeText() { status += " — \(size)" }
        }
        if let errorMessage { status = L("Нет доступа: %@", errorMessage) }
        delegate?.fileList(self, didUpdateStatus: status)
        QuickLook.selectionChanged(in: self)
    }

    // MARK: - Selection (shared by table and grid)

    private var selectedIndexes: IndexSet { selection(in: viewMode) }

    private func selection(in mode: ViewMode) -> IndexSet {
        mode == .details ? groups.indexes(forRows: tableView.selectedRowIndexes) : collectionView.selectedIndexes
    }

    private func setSelection(_ indexes: IndexSet, scrollTo index: Int? = nil) {
        if viewMode == .details {
            tableView.selectRowIndexes(groups.rows(for: indexes), byExtendingSelection: false)
            if let index, index < items.count { tableView.scrollRowToVisible(groups.row(for: index)) }
        } else {
            collectionView.setSelection(indexes, anchor: indexes.first)
            if let index { collectionView.scrollToItem(index) }
        }
        updateStatus()
    }

    private var selectedURLs: [URL] {
        selectedIndexes.compactMap { items.indices.contains($0) ? items[$0].url : nil }
    }

    /// What's selected now (the preview pane shows it).
    var selection: [URL] { selectedURLs }

    /// The item under the right click while its context menu is open (and its action runs) — not
    /// otherwise: the table keeps the row of any last click, and a key (Delete) must act on the
    /// selection, not on a row clicked before in another folder.
    private var clickedIndex: Int {
        if let keyboardMenuIndex { return keyboardMenuIndex }
        guard contextMenuOpen else { return -1 }
        return viewMode == .details ? groups.index(forRow: tableView.clickedRow) ?? -1 : collectionView.clickedIndex
    }
    private var contextMenuOpen = false
    /// Counts the context menus opened: a menu closing doesn't end the one opened right after it.
    private var contextMenuCount = 0

    /// The item a context menu opened from the keyboard (⇧F10) is for.
    private var keyboardMenuIndex: Int?

    /// ⇧F10: the context menu of the selected item (or of the folder), at the item.
    func showContextMenuForSelection() {
        let view = focusView
        guard let menu = view.menu, let window = view.window else { return }
        let index = selectedIndexes.first
        keyboardMenuIndex = index ?? -1
        var rect = view.visibleRect
        if let index {
            rect = viewMode == .details ? tableView.rect(ofRow: groups.row(for: index))
                : collectionView.layoutAttributesForItem(at: groups.indexPath(for: index))?.frame ?? rect
        }
        let point = view.convert(NSPoint(x: rect.minX + 24, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        // Actions run after the menu closes
        DispatchQueue.main.async { [weak self] in self?.keyboardMenuIndex = nil }
    }

    /// ⇧Delete with Windows keys: delete for good, after confirmation.
    func deleteSelectedForever() {
        let urls = selectedIndexes.map { items[$0].url }
        Places.deleteForever(urls, emptying: false)
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
        guard groups.index(forRow: tableView.clickedRow) != nil else { return }
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

    /// In a server's list: the selected shares that are mounted.
    private var mountedSelectedShares: [URL] {
        targetURLs.compactMap { NetworkMounter.existingMount(for: $0) }
    }

    @objc private func ejectSelectedShares(_ sender: Any?) {
        mountedSelectedShares.forEach(Places.unmount)
    }

    /// «Отключить» / «Извлечь «NAS»»: the server's shares ejected, and back to "Сеть".
    private func disconnect(from server: URL) {
        Places.disconnect(server)
    }

    @objc private func disconnectFromServer(_ sender: Any?) {
        if case .server(let server) = location { disconnect(from: server) }
    }

    @objc func openInNewTab(_ sender: Any?) {
        targetURLs.forEach { delegate?.fileList(self, open: $0, in: .newTab) }
    }

    @objc func openInNewWindow(_ sender: Any?) {
        targetURLs.forEach { delegate?.fileList(self, open: $0, in: .newWindow) }
    }

    // MARK: Finder file commands

    @objc func duplicate(_ sender: Any?) { FileCommands.duplicate(targetURLs) }
    @objc func compress(_ sender: Any?) { FileCommands.compress(targetURLs) }
    @objc func makeAlias(_ sender: Any?) { FileCommands.makeAliases(targetURLs) }

    @objc func extractArchive(_ sender: Any?) {
        targetURLs.filter(FileCommands.isZip).forEach(FileCommands.extract)
    }

    @objc func showOriginal(_ sender: Any?) {
        guard let url = targetURLs.first else { return }
        FileCommands.showOriginal(of: url) { [weak self] original in
            guard let self else { return }
            delegate?.fileList(self, reveal: original)
        }
    }

    /// Opens an app or bundle as a folder.
    @objc func showPackageContents(_ sender: Any?) {
        guard let url = targetURLs.first(where: FileCommands.isPackage) else { return }
        delegate?.fileList(self, browse: url)
    }

    @objc private func revealInFolder(_ sender: Any?) {
        guard let url = targetURLs.first else { return }
        delegate?.fileList(self, reveal: url)
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
            FileUndo.recordCreate(url)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        reload { [weak self] in self?.renameNewItem(url) }
    }

    /// Selects a just-created item and starts renaming it.
    private func renameNewItem(_ url: URL) {
        // Match by name: the listing may spell the folder differently (/tmp vs /private/tmp)
        guard let index = items.firstIndex(where: { $0.url.lastPathComponent == url.lastPathComponent }) else { return }
        setSelection(IndexSet(integer: index), scrollTo: index)
        beginRename(at: index)
    }

    @objc func renameSelected(_ sender: Any?) {
        // F2 again while renaming: keeps renaming (it only starts it)
        guard !InlineRename.isEditing(in: view.window), let index = targetRows.first else { return }
        // Several: «Переименовать N объектов»
        guard targetRows.count == 1 else {
            BatchRenameWindowController.show(for: targetRows.map { BatchRename.Item(url: items[$0].url, isFolder: items[$0].isFolder) }) { [weak self] renamed in
                self?.pendingSelection = Set(renamed.map(\.to.standardizedFileURL.path))
                self?.reload()
            }
            return
        }
        beginRename(at: index)
    }

    private func beginRename(at index: Int) {
        let file = items[index]
        if viewMode == .details {
            tableView.editColumn(0, row: groups.row(for: index), with: nil, select: true)
            if let field = (tableView.view(atColumn: 0, row: groups.row(for: index), makeIfNecessary: false) as? NSTableCellView)?.textField {
                InlineRename.began(field)
            }
            // The table selects the whole name once editing starts; narrow it to the name without extension
            // (view-based tables edit in the cell's text field, so use the window's field editor)
            DispatchQueue.main.async { [weak self] in
                (self?.view.window?.firstResponder as? NSTextView)?.setSelectedRange(
                    FileOps.baseNameRange(of: file.name, isFolder: file.isFolder))
            }
        } else {
            collectionView.scrollToItem(index)
            collectionView.layoutSubtreeIfNeeded()
            let item = collectionView.item(at: groups.indexPath(for: index)) as? FileGridItem
            item?.beginRename { [weak self] newName in self?.rename(file.url, to: newName) }
        }
    }

    /// Table cells commit renames through their text field's action.
    @objc private func renameEdited(_ sender: NSTextField) {
        InlineRename.resetCursor(in: view.window)
        guard let index = groups.index(forRow: tableView.row(for: sender)), items.indices.contains(index) else { return }
        rename(items[index].url, to: sender.stringValue)
    }

    private func rename(_ url: URL, to rawName: String) {
        // (Return, then the end of editing: the second time the file has its new name already)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? trimmed : FileOps.fullName(trimmed, renaming: url)
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        if !newName.isEmpty, !newName.contains("/"), destination.path != url.path {
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                FileUndo.recordRename(from: url, to: destination)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        // Reload either way so a rejected name reverts on screen; the item stays selected under its
        // (new or old) name, even if the reload has to wait for the name field to close
        let renamed = FileManager.default.fileExists(atPath: destination.path) && !newName.isEmpty
        pendingSelectionName = renamed ? destination.lastPathComponent : url.lastPathComponent
        reload()
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
            for row in visible.lowerBound..<visible.upperBound {
                guard let index = groups.index(forRow: row), items.indices.contains(index) else { continue }
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
                cell?.imageView?.alphaValue = clipboard.isCut(items[index].url) ? Self.cutAlpha : 1
            }
        } else {
            for indexPath in collectionView.indexPathsForVisibleItems() where items.indices.contains(groups.index(of: indexPath)) {
                (collectionView.item(at: indexPath) as? FileGridItem)?.setCut(clipboard.isCut(items[groups.index(of: indexPath)].url))
            }
        }
    }

    static let cutAlpha: CGFloat = 0.4

    @objc private func refresh(_ sender: Any?) {
        #if DEBUG
        ExplorerWindowController.debugRefreshes += 1
        #endif
        reload()
    }

    @objc func quickLook(_ sender: Any?) {
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
            return (tableView.view(atColumn: 0, row: groups.row(for: index), makeIfNecessary: false) as? NSTableCellView)?.imageView
        }
        return collectionView.item(at: groups.indexPath(for: index))?.imageView
    }

    /// ⌘I / ⌥↩ / context menu: the selection, or the folder itself when nothing is selected.
    @objc func showProperties(_ sender: Any?) {
        let urls = targetURLs
        PropertiesWindowController.show(for: urls.isEmpty ? [directory].compactMap { $0 } : urls)
    }

    // MARK: - Trash, sharing

    @objc private func putBackFromTrash(_ sender: Any?) {
        let failed = Places.putBack(targetURLs)
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("Не удалось вернуть: %@", failed.map(\.lastPathComponent).joined(separator: ", "))
            alert.informativeText = L("Для этих объектов не сохранилось исходное расположение.")
            alert.runModal()
        }
    }

    @objc func deleteForever(_ sender: Any?) {
        Places.deleteForever(targetURLs, emptying: false)
    }

    @objc private func emptyTrash(_ sender: Any?) {
        Places.emptyTrash()
    }

    @objc private func openFullDiskAccess(_ sender: Any?) {
        Places.openFullDiskAccessSettings()
    }

    /// "Поделиться…": the system share picker (AirDrop, Messages, Mail…) next to the item.
    @objc func share(_ sender: Any?) {
        guard let index = targetRows.first else { return }
        let picker = NSSharingServicePicker(items: targetURLs)
        if viewMode == .details {
            picker.show(relativeTo: tableView.rect(ofRow: groups.row(for: index)), of: tableView, preferredEdge: .maxY)
        } else if let frame = collectionView.layoutAttributesForItem(at: groups.indexPath(for: index))?.frame {
            picker.show(relativeTo: frame, of: collectionView, preferredEdge: .maxY)
        }
    }

    /// AirDrop: the selected files to a nearby device; with nothing selected, Finder's AirDrop window.
    @objc func sendViaAirDrop(_ sender: Any?) {
        let urls = targetURLs
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            Places.openAirDrop()
            return
        }
        service.perform(withItems: urls)
    }

    /// The command bar's «Открыть в терминале»: the selected folders (scripts run), or the folder shown.
    @objc func openInTerminal(_ sender: Any?) {
        let urls = targetURLs
        if !urls.isEmpty { TerminalLauncher.open(urls) } else if let directory { TerminalLauncher.open(folder: directory) }
    }

    @objc func assignTags(_ sender: Any?) {
        guard let index = targetRows.first ?? selectedIndexes.first, items.indices.contains(index) else { return }
        let urls = targetURLs
        let (anchor, rect) = itemFrame(index)
        // After the menu has closed (a popover can't show while the menu tracks)
        DispatchQueue.main.async { TagAssigner.show(for: urls.isEmpty ? [self.items[index].url] : urls, relativeTo: rect, of: anchor) }
    }

    /// Where an item is drawn, in the view showing it.
    private func itemFrame(_ index: Int) -> (NSView, NSRect) {
        viewMode == .details ? (tableView, tableView.rect(ofRow: groups.row(for: index)))
            : (collectionView, collectionView.layoutAttributesForItem(at: groups.indexPath(for: index))?.frame ?? .zero)
    }

    @objc func customizeFolder(_ sender: Any?) {
        guard let index = targetRows.first ?? selectedIndexes.first, items.indices.contains(index) else { return }
        let anchor: NSView, rect: NSRect
        if viewMode == .details {
            anchor = tableView
            rect = tableView.rect(ofRow: groups.row(for: index))
        } else {
            anchor = collectionView
            rect = collectionView.layoutAttributesForItem(at: groups.indexPath(for: index))?.frame ?? .zero
        }
        FolderCustomizationController.show(for: items[index].url, relativeTo: rect, of: anchor)
    }

    @objc func toggleTag(_ sender: NSMenuItem) { FileContextMenu.toggleTag(sender) }

    @objc private func sortByKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: tableView.sortDescriptors.first?.ascending ?? true)]
    }

    @objc private func toggleFoldersOnTop(_ sender: NSMenuItem) {
        foldersOnTop.toggle()
        if let directory { ViewMode.rememberSortOrder(sortOrder, for: directory) }
        refilter(keepSelection: true)
        NotificationCenter.default.post(name: .foldersOnTopChanged, object: nil)
    }

    @objc private func groupByKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, key != groupBy else { return }
        groupBy = key
        if let directory { ViewMode.rememberSortOrder(sortOrder, for: directory) }
        refilter(keepSelection: true)
    }

    /// Group headings in the icon views: a band above each group (in a list going sideways, none —
    /// its columns begin a group each).
    private func updateGroupHeaders() {
        let height: CGFloat = groups.isGrouped && !viewMode.scrollsHorizontally ? GroupHeaderView.height + 4 : 0
        flowLayout.headerReferenceSize = NSSize(width: 0, height: height)
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
            FileUndo.recordCreate(url)
            reload { [weak self] in self?.renameNewItem(url) }
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
        if menuItem.action == #selector(toggleItemInfo(_:)) {
            // The folder's own choice, whichever menu shows it
            menuItem.state = showsItemInfo ? .on : .off
            return directory != nil
        }
        switch menuItem.action {
        case #selector(cut(_:)), #selector(copy(_:)), #selector(moveToTrash(_:)), #selector(deleteForever(_:)), #selector(openSelected(_:)),
             #selector(renameSelected(_:)), #selector(openInNewTab(_:)), #selector(openInNewWindow(_:)),
             #selector(duplicate(_:)), #selector(compress(_:)), #selector(makeAlias(_:)):
            return !targetRows.isEmpty
        case #selector(showOriginal(_:)): return targetURLs.contains(where: FileCommands.isAlias)
        case #selector(showPackageContents(_:)): return targetURLs.contains(where: FileCommands.isPackage)
        case #selector(extractArchive(_:)): return targetURLs.contains(where: FileCommands.isZip)
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
        if menu === headerMenu { return fillHeaderMenu(menu) }
        contextMenuOpen = true
        contextMenuCount += 1
        // Like Explorer: right-clicking an item selects it (the menu acts on the selection)
        let clicked = clickedIndex
        if clicked >= 0 && !selectedIndexes.contains(clicked) { setSelection(IndexSet(integer: clicked)) }
        defer {
            MenuStyle.decorate(menu)
            // Whatever this menu is, the next one may be a folder's with «Импортировать с iPhone»
            DeviceImport.seed(menu)
        }
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if clickedIndex >= 0 && location == .network {
            add(L("Подключиться"), #selector(openSelected(_:)))
            return
        }
        if clickedIndex >= 0, case .server = location {
            add(L("Открыть"), #selector(openSelected(_:)))
            add(L("Открыть в новой вкладке"), #selector(openInNewTab(_:)))
            if !mountedSelectedShares.isEmpty {
                menu.addItem(.separator())
                add(L("Извлечь"), #selector(ejectSelectedShares(_:)))
            }
            return
        }
        if clickedIndex >= 0 && location == .trash {
            add(L("Вернуть"), #selector(putBackFromTrash(_:)))
            add(L("Удалить навсегда"), #selector(deleteForever(_:)))
            menu.addItem(.separator())
            add(L("Быстрый просмотр"), #selector(quickLook(_:)))
            add(L("Свойства"), #selector(showProperties(_:)))
            return
        }
        if clickedIndex < 0 && location == .trash {
            add(L("Очистить Корзину"), #selector(emptyTrash(_:)))
            if errorMessage != nil { add(L("Открыть настройки «Полный доступ к диску»…"), #selector(openFullDiskAccess(_:))) }
            return
        }
        if clickedIndex >= 0 {
            let rows = targetRows
            FileContextMenu.addItems(to: menu, for: targetURLs, target: self,
                                     folderTabs: rows.contains { items[$0].isFolder },
                                     customizableFolder: rows.count == 1 && rows.first.map { items[$0].isFolder } == true)
            if search != nil, rows.count == 1, let open = menu.items.firstIndex(where: { $0.action == #selector(openSelected(_:)) }) {
                // Search and tag results come from anywhere: Explorer's "Open file location"
                let reveal = NSMenuItem(title: L("Показать в папке"), action: #selector(revealInFolder(_:)), keyEquivalent: "")
                reveal.target = self
                menu.insertItem(reveal, at: open + 1)
            }
        } else {
            // A server, as in Finder: «Извлечь «NAS»» first
            if case .server = location, case .connected = serverLogin {
                add(L("Извлечь «%@»", menuName(location?.title ?? "")), #selector(disconnectFromServer(_:)))
                menu.addItem(.separator())
            }
            let viewItem = NSMenuItem(title: L("Вид"), action: nil, keyEquivalent: "")
            let viewMenu = NSMenu()
            for mode in ViewMode.allCases {
                let item = viewMenu.addItem(withTitle: mode.title, action: #selector(changeViewMode(_:)), keyEquivalent: "")
                item.target = self
                item.tag = mode.rawValue
            }
            viewMenu.addItem(.separator())
            let info = viewMenu.addItem(withTitle: L("Показывать свойства"), action: #selector(toggleItemInfo(_:)), keyEquivalent: "")
            info.target = self
            info.state = showsItemInfo ? .on : .off
            info.isEnabled = directory != nil
            viewMenu.addItem(.separator())
            let applyAll = viewMenu.addItem(withTitle: L("Применить ко всем папкам"), action: #selector(applyToAllFolders(_:)), keyEquivalent: "")
            applyAll.target = self
            applyAll.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
            viewItem.submenu = viewMenu
            menu.addItem(viewItem)

            let sortMenu = makeSortMenu()
            menu.addItem(withTitle: L("Сортировка"), action: nil, keyEquivalent: "").submenu = sortMenu
            menu.addItem(withTitle: L("Группировать по"), action: nil, keyEquivalent: "").submenu = makeGroupMenu()
            add(L("Обновить"), #selector(refresh(_:)))
            // The network and a server hold no files: nothing to create, paste or copy the path of
            if showingNetwork { return }
            menu.addItem(.separator())
            menu.addItem(NewItemTemplate.menuItem(target: self, action: #selector(createNewItem(_:)), withFolder: false))
            if let directory, canCreateItems { DeviceImport.addItems(to: menu, into: directory) }
            menu.addItem(.separator())
            add(L("Копировать путь к папке"), #selector(copyPath(_:)))
            if let directory, let terminal = TerminalLauncher.menuItem(for: [directory]) { menu.addItem(terminal) }
            if let directory { OpenWithMenu.mainMenuItems(for: [directory]).forEach(menu.addItem) }
            add(L("Свойства"), #selector(showProperties(_:)))
            // Like Finder: «Новая папка» and «Вставить» first (paste only when there's something to paste)
            if directory != nil {
                NewItemTemplate.addFolderAndPaste(to: menu, target: self, action: #selector(createNewItem(_:)), paste: #selector(paste(_:)))
            }
        }
    }

    /// "Сортировка": the usual keys, the rarer ones under "Дополнительно", the direction.
    func makeSortMenu() -> NSMenu {
        let sortMenu = NSMenu()
        let current = tableView.sortDescriptors.first
        func addKey(_ key: FileColumn, to menu: NSMenu) {
            let item = menu.addItem(withTitle: key.title, action: #selector(sortByKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = (current?.key ?? "name") == key.rawValue ? .on : .off
        }
        // All keys on one level, in Finder's order: the dates together
        for key in [FileColumn.name, .type, .opened, .added, .date, .created, .size, .tags] { addKey(key, to: sortMenu) }
        sortMenu.addItem(.separator())
        for (ascending, title) in [(true, L("По возрастанию")), (false, L("По убыванию"))] {
            let item = sortMenu.addItem(withTitle: title, action: #selector(sortOrder(_:)), keyEquivalent: "")
            item.target = self
            item.tag = ascending ? 1 : 0
            item.state = (current?.ascending ?? true) == ascending ? .on : .off
        }
        // Explorer keeps folders first; Finder sorts them in among the files (this folder's own)
        sortMenu.addItem(.separator())
        let foldersFirst = sortMenu.addItem(withTitle: L("Папки сверху"), action: #selector(toggleFoldersOnTop(_:)), keyEquivalent: "")
        foldersFirst.target = self
        foldersFirst.state = foldersOnTop ? .on : .off
        return sortMenu
    }

    /// Finder's and Explorer's «Группировать по» (this folder's own): a menu of its own.
    func makeGroupMenu() -> NSMenu {
        let groupMenu = NSMenu()
        for key in [""] + FileGrouping.keys.map(\.rawValue) {
            let item = groupMenu.addItem(withTitle: key.isEmpty ? L("Без групп") : FileColumn(rawValue: key)?.title ?? key,
                                         action: #selector(groupByKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = groupBy == key ? .on : .off
            if key.isEmpty { groupMenu.addItem(.separator()) }
        }
        return groupMenu
    }

    /// "Создать ▸": a folder and the document templates.
    func makeNewItemMenu() -> NSMenu {
        let item = NewItemTemplate.menuItem(target: self, action: #selector(createNewItem(_:)))
        let menu = item.submenu ?? NSMenu()
        item.submenu = nil
        return menu
    }

    var canCreateItems: Bool { directory != nil && location != .trash && search == nil }

    /// «Импортировать с iPhone» saves into the folder shown.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        DeviceImport.requestor(into: canCreateItems ? directory : nil, in: view, sendType: sendType, returnType: returnType)
            ?? super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // MARK: - Selection commands

    @objc func selectAllItems(_ sender: Any?) { setSelection(IndexSet(items.indices)) }
    @objc func selectNone(_ sender: Any?) { setSelection(IndexSet()) }

    @objc func invertSelection(_ sender: Any?) {
        setSelection(IndexSet(items.indices).subtracting(selectedIndexes))
    }

    var hasSelection: Bool { !selectedIndexes.isEmpty }

    /// "Добавить в избранное": the selected folders, or the folder shown when nothing is selected.
    @objc func addToFavorites(_ sender: Any?) {
        let folders = selectedIndexes.map { items[$0] }.filter(\.isFolder).map(\.url)
        if !folders.isEmpty { folders.forEach { SidebarConfig.pin($0) } } else if let directory { SidebarConfig.pin(directory) }
    }

    func menuDidClose(_ menu: NSMenu) {
        // Menu actions are sent after the menu closes; forget the clicked item afterwards — unless
        // another item was right-clicked with this menu open: its menu is coming (or open) by then,
        // and forgetting its item would make it the folder's menu
        let count = contextMenuCount
        let clicks = collectionView.menuClicks
        DispatchQueue.main.async { [weak self] in
            guard let self, count == contextMenuCount, clicks == collectionView.menuClicks else { return }
            contextMenuOpen = false
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { groups.rowCount }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // Picked by the user (menu or a column's header): this folder's own sorting
        if !isRestoringFolderView, let directory, tableView.sortDescriptors.first?.key != nil {
            ViewMode.rememberSortOrder(sortOrder, for: directory)
        }
        // (Restoring a folder's sorting before its contents come: nothing to sort yet)
        if !isRestoringFolderView { refilter(keepSelection: true) }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        groups.index(forRow: row).flatMap { items.indices.contains($0) ? items[$0].url as NSURL : nil }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Onto a folder row: into that folder; anywhere else: into the current folder
        if dropOperation == .on, let index = groups.index(forRow: row), items.indices.contains(index), items[index].isFolder {
            let operation = FileDrop.operation(for: info, into: items[index].url)
            if operation != [] { return operation }
        }
        guard let directory else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return FileDrop.operation(for: info, into: directory)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if dropOperation == .on, let index = groups.index(forRow: row), items.indices.contains(index), items[index].isFolder {
            return FileDrop.perform(info, into: items[index].url)
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
        if let title = groups.title(forRow: row) { return GroupHeaderView.make(in: tableView, title: title) }
        // (The table may still count the rows of what it showed last: hidden in icon views, it isn't reloaded)
        guard let column = tableColumn?.identifier.rawValue, let index = groups.index(forRow: row), items.indices.contains(index) else { return nil }
        let item = items[index]
        let cell = tableView.makeView(withIdentifier: .init(column), owner: self) as? NSTableCellView
            ?? makeCell(identifier: column)
        switch column {
        case "name":
            cell.imageView?.image = image(for: item)
            cell.imageView?.alphaValue = FileClipboard.shared.isCut(item.url) ? Self.cutAlpha : 1
            cell.textField?.stringValue = item.name
            (cell.subviews.first { $0.identifier == CloudProgressBar.cellIdentifier } as? CloudProgressBar)?.url = item.url
            (cell.subviews.first { $0.identifier == CloudDownloadButton.cellIdentifier } as? CloudDownloadButton)?.show(item.url, cloudOnly: item.isCloudOnly)
        case "folder":
            cell.textField?.stringValue = cellText(column, item)
            cell.textField?.toolTip = item.url.deletingLastPathComponent().path
        case "tags":
            let dots = FileTags.dots(for: item.tags, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            cell.textField?.attributedStringValue = dots
            cell.textField?.toolTip = item.tags.map(\.name).joined(separator: ", ")
        default:
            cell.textField?.stringValue = cellText(column, item)
        }
        return cell
    }

    /// What a column shows for an item, as text.
    private func cellText(_ column: String, _ item: FileItem) -> String {
        switch FileColumn(rawValue: column) {
        case .name: item.name
        case .date: item.modified.map(Self.dateFormatter.string(from:)) ?? ""
        case .created: item.created.map(Self.dateFormatter.string(from:)) ?? ""
        case .added: item.added.map(Self.dateFormatter.string(from:)) ?? ""
        case .opened: item.lastOpened.map(Self.dateFormatter.string(from:)) ?? ""
        case .type: item.typeDescription
        case .size: item.sizeDescription ?? ""
        case .tags: item.tags.map(\.name).joined(separator: ", ")
        case .folder:
            {
                let folder = item.url.deletingLastPathComponent().path
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
            }()
        case nil: ""
        }
    }

    // MARK: - Columns

    private let headerMenu = NSMenu()
    private var headerMenuColumn: NSTableColumn?

    /// Explorer's header menu: fit the column (or all of them) to their contents, show / hide columns.
    private func fillHeaderMenu(_ menu: NSMenu) {
        let clicked = (tableView.headerView as? FileHeaderView)?.menuColumn ?? -1
        headerMenuColumn = tableView.tableColumns.indices.contains(clicked) ? tableView.tableColumns[clicked] : nil
        @discardableResult
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        add(L("Столбец по размеру содержимого"), #selector(fitClickedColumn(_:))).isEnabled = headerMenuColumn != nil
        add(L("Все столбцы по размеру содержимого"), #selector(fitAllColumns(_:)))
        menu.addItem(.separator())
        for column in FileColumn.allCases where column != .folder {
            let item = add(column.title, #selector(toggleColumn(_:)))
            item.representedObject = column.rawValue
            item.state = tableView.tableColumn(withIdentifier: .init(column.rawValue))?.isHidden == false ? .on : .off
        }
        menu.autoenablesItems = false
        // The name can't be hidden
        menu.items.first { ($0.representedObject as? String) == FileColumn.name.rawValue }?.isEnabled = false
        MenuStyle.decorate(menu)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != FileColumn.name.rawValue,
              let column = tableView.tableColumn(withIdentifier: .init(id)) else { return }
        column.isHidden.toggle()
        if !column.isHidden { tableView.scrollColumnToVisible(tableView.column(withIdentifier: column.identifier)) }
        saveColumns()
    }

    @objc private func fitClickedColumn(_ sender: Any?) {
        if let column = headerMenuColumn { fit(column) }
        saveColumns()
    }

    @objc private func fitAllColumns(_ sender: Any?) {
        tableView.tableColumns.filter { !$0.isHidden }.forEach(fit)
        saveColumns()
    }

    /// As wide as its widest text (the first few thousand rows) or its title.
    private func fit(_ column: NSTableColumn) {
        let id = column.identifier.rawValue
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var width = (column.title as NSString).size(withAttributes: [.font: column.headerCell.font ?? NSFont.systemFont(ofSize: 11)]).width + 24
        for item in items.prefix(3000) {
            let text = id == "tags" ? String(repeating: "●", count: item.tags.count) : cellText(id, item)
            width = max(width, (text as NSString).size(withAttributes: [.font: font]).width + 12)
        }
        if id == FileColumn.name.rawValue { width += 32 }  // the icon
        column.width = min(ceil(width), 700)
    }

    private func saveColumns() {
        var layout = FileColumn.Layout(order: [], widths: [:], hidden: [])
        for tableColumn in tableView.tableColumns {
            guard let column = FileColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
            layout.order.append(column)
            layout.widths[column] = tableColumn.width
            if column != .folder, tableColumn.isHidden { layout.hidden.insert(column) }
        }
        FileColumn.savedLayout = layout
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
            // iCloud's upload / download of the file
            let cloud = CloudProgressBar()
            cloud.identifier = CloudProgressBar.cellIdentifier
            cloud.uploadsOnly = true
            cloud.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(cloud)
            // Under the name (the icon is too small for it)
            NSLayoutConstraint.activate([
                cloud.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: 2),
                cloud.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                cloud.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -1),
                cloud.heightAnchor.constraint(equalToConstant: 4),
            ])
            // Finder's cloud for a file in iCloud only, at the name column's end (a click downloads it)
            let cloudOnly = CloudDownloadButton()
            cloudOnly.identifier = CloudDownloadButton.cellIdentifier
            cloudOnly.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(cloudOnly)
            NSLayoutConstraint.activate([
                cloudOnly.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                cloudOnly.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: cloudOnly.leadingAnchor, constant: -4),
            ])
            text.isEditable = true
            text.target = self
            text.action = #selector(renameEdited(_:))
            // A click elsewhere or another app keeps what was typed (as in icon views), not only Return
            text.cell?.sendsActionOnEndEditing = true
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
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        // (The name ends before the cloud)
        if identifier != "name" { text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4).isActive = true }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == "name", let index = groups.index(forRow: row), items.indices.contains(index) else { return nil }
        return items[index].name
    }

    // A group's heading: across the table, not selectable
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { groups.title(forRow: row) != nil }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { groups.title(forRow: row) == nil }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        groups.title(forRow: row) != nil ? GroupHeaderView.height : tableView.rowHeight
    }

    // MARK: - NSCollectionViewDataSource

    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.sectionCount }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        groups.itemCount(inSection: section)
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GroupHeaderView.identifier, for: indexPath)
        (header as? GroupHeaderView)?.title = groups.titles.indices.contains(indexPath.section) ? groups.titles[indexPath.section] : ""
        return header
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath) as! FileGridItem
        let file = items[groups.index(of: indexPath)]
        let look = collectionView.collectionViewLayout === lookLayout ? finderLook : nil
        item.customIconSide = look?.iconSize
        item.labelTextColor = look?.textColor
        item.showsItemInfo = showsItemInfo
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
    /// On a server every icon is a trip over the network: the type's icon is shown at once and the
    /// real one (a folder's look, an app's icon) is made in the background, then put in.
    private func quickIcon(_ file: FileItem) -> NSImage {
        guard isRemoteFolder, !file.hasIcon else { return file.icon }
        loadIcon(file)
        let ext = file.isFolder ? "/" : file.url.pathExtension.lowercased()
        if let known = Self.typeIcons[ext] { return known }
        // (One image per type: the icon's measured shape is remembered per image)
        let icon = file.isFolder ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        Self.typeIcons[ext] = icon
        return icon
    }
    private static var typeIcons: [String: NSImage] = [:]

    /// The folder shown is on a server (not a local disk).
    private var isRemoteFolder = false
    private var loadingIcons: Set<String> = []
    private static let iconQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private func loadIcon(_ file: FileItem) {
        let path = file.url.path
        guard loadingIcons.insert(path).inserted else { return }
        let url = file.url, isFolder = file.isFolder, alias = file.aliasTarget, tagged = !file.tagNames.isEmpty
        Self.iconQueue.addOperation { [weak self] in
            let icon = FileItem.makeIcon(url: url, isFolder: isFolder, aliasTarget: alias, tags: tagged ? FileTags.tags(of: url) : [])
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingIcons.remove(path)
                guard let index = self.items.firstIndex(where: { $0.url.path == path }) else { return }
                let item = self.items[index]
                item.icon = icon
                // (A preview may have come first: it stays)
                let key = "\(Int(self.viewMode.iconSize))|\(path)" as NSString
                guard self.thumbnails.object(forKey: key) == nil else { return }
                if self.viewMode == .details {
                    let row = self.groups.row(for: index)
                    if row < self.tableView.numberOfRows, let column = self.tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) {
                        self.tableView.reloadData(forRowIndexes: [row], columnIndexes: [column])
                    }
                } else if let cell = self.collectionView.item(at: self.groups.indexPath(for: index)) as? FileGridItem {
                    cell.setImage(icon)
                }
            }
        }
    }

    private func image(for file: FileItem) -> NSImage {
        // Small icons: previews too, as in Finder's lists — for pictures, videos and PDFs
        guard !file.isFolder, !AliasIcon.isContainer(file),
              viewMode.usesThumbnails || Self.hasSmallPreview(AliasIcon.previewSource(file)) else { return quickIcon(file) }
        let side = viewMode.iconSize
        let key = "\(Int(side))|\(file.url.path)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard !requestedThumbnails.contains(key) else { return quickIcon(file) }
        requestedThumbnails.insert(key)

        let request = QLThumbnailGenerator.Request(
            fileAt: AliasIcon.previewSource(file), size: CGSize(width: side, height: side),
            scale: view.window?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        // Finder's look: documents as rounded pages, pictures as rounded cards
        request.iconMode = true
        let path = file.url.path
        let isAlias = file.aliasTarget != nil
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let shown = representation?.nsImage else { return }
            let image = isAlias ? AliasIcon.badged(shown) : shown
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnails.setObject(image, forKey: key)
                guard self.viewMode.iconSize == side, let index = self.items.firstIndex(where: { $0.url.path == path }) else { return }
                if self.viewMode == .details {
                    let row = self.groups.row(for: index)
                    if row < self.tableView.numberOfRows, let column = self.tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) {
                        self.tableView.reloadData(forRowIndexes: [row], columnIndexes: [column])
                    }
                    return
                }
                guard let item = self.collectionView.item(at: self.groups.indexPath(for: index)) as? FileGridItem else { return }
                item.setImage(image)
            }
        }
        return quickIcon(file)
    }

    private static func hasSmallPreview(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
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
    private let slowClick = SlowClickRename()

    override func mouseDown(with event: NSEvent) {
        slowClick.cancel()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let onName = row >= 0 && column(at: point) == 0
        if onName {
            // Slow click on the name of the row that was already selected → rename
            let candidate = SlowClickRename.isPlainClick(event) && selectedRowIndexes == IndexSet(integer: row)
                && nameTextRect(row: row)?.contains(point) == true
            let start = NSEvent.mouseLocation
            super.mouseDown(with: event)  // tracks until mouse up (or runs a file drag)
            let moved = hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) > 3
            if candidate, !moved, !(window?.firstResponder is NSTextView) {
                slowClick.schedule { [weak self] in
                    guard let self, self.selectedRowIndexes == IndexSet(integer: row) else { return }
                    self.onRename?()
                }
            }
            return
        }
        guard event.clickCount == 1 else { return super.mouseDown(with: event) }

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
            // (Not a group's heading: it isn't selectable)
            let touched = IndexSet(integersIn: rows.lowerBound..<rows.upperBound).filter { self.delegate?.tableView?(self, shouldSelectRow: $0) ?? true }
            selectRowIndexes(base.union(IndexSet(touched)), byExtendingSelection: false)
        }
    }

    /// Clicking a name must not start editing by itself (the stock table does that on any click):
    /// renaming starts only from the slow click, F2 / Return or the menu, which call `editColumn`.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextField { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    /// Where the file name's text is drawn in a row (clicks next to it don't rename).
    private func nameTextRect(row: Int) -> NSRect? {
        guard let field = (view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField else { return nil }
        let width = min(field.attributedStringValue.size().width + 6, field.bounds.width)
        return field.convert(NSRect(x: 0, y: 0, width: width, height: field.bounds.height), to: self)
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
        slowClick.cancel()
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

/// The bar above the Trash ("Корзина", "Очистить") and a server ("Подключен: …", "Отключить"),
/// like Finder's.
private final class PlaceBar: NSView {
    static let height: CGFloat = 40

    struct Button {
        let title: String
        let toolTip: String?
        let enabled: Bool
        let action: () -> Void
    }

    private let title = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var actions: [() -> Void] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let line = NSBox()
        line.boxType = .separator
        for view in [title, buttons, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `emphasized`: a place's name in bold (the Trash); otherwise a quiet status line (a server).
    func show(_ text: String, emphasized: Bool, buttons list: [Button]) {
        title.stringValue = text
        title.font = .systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
        title.textColor = emphasized ? .labelColor : .secondaryLabelColor
        actions = list.map(\.action)
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in list.enumerated() {
            let button = NSButton(title: item.title, target: self, action: #selector(press(_:)))
            button.bezelStyle = .push
            button.controlSize = .regular
            button.tag = index
            button.toolTip = item.toolTip
            button.isEnabled = item.enabled
            buttons.addArrangedSubview(button)
        }
    }

    @objc private func press(_ sender: NSButton) {
        if actions.indices.contains(sender.tag) { actions[sender.tag]() }
    }
}

/// The columns of the "Таблица" view.
enum FileColumn: String, CaseIterable {
    case name, date, created, added, opened, type, size, tags, folder

    var title: String {
        switch self {
        case .name: L("Имя")
        case .date: L("Дата изменения")
        case .created: L("Дата создания")
        case .added: L("Дата добавления")
        case .opened: L("Дата последнего открытия")
        case .type: L("Тип")
        case .size: L("Размер")
        case .tags: L("Теги")
        case .folder: L("Папка")
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: 320
        case .date, .created, .added, .opened: 150
        case .type: 160
        case .size: 90
        case .tags: 70
        case .folder: 220
        }
    }

    var isSortable: Bool { true }

    struct Layout {
        var order: [FileColumn]
        var widths: [FileColumn: CGFloat]
        var hidden: Set<FileColumn>
    }

    private static let key = "listColumns"

    /// Shared by every window; new columns (not in the saved order) come last, hidden.
    static var savedLayout: Layout {
        get {
            let stored = AppDefaults.store.dictionary(forKey: key)
            let order = (stored?["order"] as? [String])?.compactMap(FileColumn.init(rawValue:)) ?? []
            let widths = (stored?["widths"] as? [String: Double] ?? [:]).reduce(into: [FileColumn: CGFloat]()) {
                if let column = FileColumn(rawValue: $1.key) { $0[column] = $1.value }
            }
            var hidden = Set((stored?["hidden"] as? [String])?.compactMap(FileColumn.init(rawValue:)) ?? [.created, .added])
            let missing = allCases.filter { !order.contains($0) }
            if stored != nil { hidden.formUnion(missing.filter { $0 != .folder && $0 != .name }) }
            hidden.remove(.name)
            return Layout(order: order + missing, widths: widths, hidden: hidden)
        }
        set {
            AppDefaults.store.set([
                "order": newValue.order.map(\.rawValue),
                "widths": Dictionary(uniqueKeysWithValues: newValue.widths.map { ($0.key.rawValue, Double($0.value)) }),
                "hidden": newValue.hidden.map(\.rawValue),
            ], forKey: key)
        }
    }
}

/// Remembers which column a right click hit (for "Столбец по размеру содержимого").
final class FileHeaderView: NSTableHeaderView {
    private(set) var menuColumn = -1

    override func menu(for event: NSEvent) -> NSMenu? {
        menuColumn = column(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }
}
