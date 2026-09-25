import AppKit

/// Navigation pane: favourites, places and tags, as in Finder. Files dropped on an entry go
/// there (into a folder or disk, to the Trash, get the tag); folders dropped between the
/// favourites are pinned; favourites are reordered by dragging.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    final class Section {
        enum Kind { case favorites, places, tags }
        let kind: Kind
        let title: String
        let items: [Item]
        init(_ kind: Kind, title: String, items: [Item]) { self.kind = kind; self.title = title; self.items = items }
    }

    final class Item {
        let title: String
        let url: URL
        let symbol: String
        /// Tag entries show a colored dot instead of a symbol.
        let tagColor: Int?
        /// Removable and network volumes get an eject button.
        var ejectable = false
        /// Entries that do something instead of navigating (AirDrop).
        var action: (() -> Void)?
        var toolTip: String?
        var place: SidebarConfig.Place?
        init(title: String, url: URL, symbol: String, tagColor: Int? = nil) {
            self.title = title; self.url = url; self.symbol = symbol; self.tagColor = tagColor
        }
    }

    var onSelect: ((URL) -> Void)?
    /// Room at the top for the window buttons (the sidebar runs under the title bar).
    var topInset: CGFloat = 0

    private let outlineView = NSOutlineView()
    private var sections: [Section] = []
    private var currentURL: URL?
    private var suppressSelection = false

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.floatsGroupRows = false
        // Finder's macOS 26 sidebar: roomy rows, larger symbols
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 30
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([.fileURL, Self.favoriteType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.draggingDestinationFeedbackStyle = .sourceList
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: topInset),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        view = background

        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.add(name, center: NSWorkspace.shared.notificationCenter) { [weak self] in self?.rebuild() }
        }
        observers.add(SidebarConfig.didChange) { [weak self] in self?.rebuild() }
        observers.add(TagLibrary.didChange) { [weak self] in self?.rebuild() }
        rebuild()
    }

    private let observers = Observers()
    private static let favoriteType = NSPasteboard.PasteboardType("dev.winex.sidebar-favorite")

    private func rebuild() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        // Favourites: the user's folders in the user's order (gone ones are skipped, not forgotten)
        let standard = SidebarConfig.standardFavorites
        let favorites: [Item] = SidebarConfig.favoritePaths.compactMap { path in
            guard fm.fileExists(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            let title = standard.first { $0.url.path == path }?.title ?? url.displayName
            return Item(title: title, url: url, symbol: SidebarConfig.symbol(for: url))
        }
        // "Места", like Finder: iCloud Drive, disks and shares, AirDrop, the network, the Trash
        var places: [Item] = []
        func add(_ place: SidebarConfig.Place, _ item: Item) {
            guard SidebarConfig.shows(place) else { return }
            item.place = place
            places.append(item)
        }
        add(.computer, Item(title: L("Этот Mac"), url: Places.computerURL, symbol: "desktopcomputer"))
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            add(.iCloud, Item(title: "iCloud Drive", url: iCloud, symbol: "icloud"))
        }
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
                                      .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey]
        for url in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeLocalizedName ?? url.lastPathComponent
            let item: Item
            let place: SidebarConfig.Place
            if values?.volumeIsLocal == false {
                let server = Places.serverName(ofVolume: url)
                item = Item(title: server.map { L("%@ на %@", name, $0) } ?? name, url: url, symbol: "externaldrive.connected.to.line.below")
                item.toolTip = (try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting?.absoluteString
                place = .servers
            } else {
                let isInternal = values?.volumeIsInternal ?? true
                item = Item(title: name, url: url, symbol: isInternal ? "internaldrive" : "externaldrive")
                place = isInternal ? .internalDisks : .externalDisks
            }
            item.ejectable = !(values?.volumeIsRootFileSystem ?? false)
                && (values?.volumeIsLocal == false || values?.volumeIsEjectable == true || values?.volumeIsRemovable == true)
            add(place, item)
        }
        if let link = URL(string: "x-winex-airdrop://airdrop") {
            let airDrop = Item(title: "AirDrop", url: link, symbol: "airplayaudio")
            airDrop.action = { Places.openAirDrop() }
            add(.airDrop, airDrop)
        }
        add(.network, Item(title: L("Сеть"), url: Places.networkURL, symbol: "network"))
        add(.trash, Item(title: L("Корзина"), url: Places.trashURL, symbol: "trash"))

        sections = [Section(.favorites, title: L("Избранное"), items: favorites)]
        if !places.isEmpty { sections.append(Section(.places, title: L("Места"), items: places)) }
        // The tags chosen in Settings ▸ Теги; clicking one lists every file with it
        let tags = TagLibrary.entries.filter(\.inSidebar)
        if SidebarConfig.showsTags, !tags.isEmpty {
            sections.append(Section(.tags, title: L("Теги"), items: tags.map {
                Item(title: $0.name, url: Location.tagURL($0.name), symbol: "tag", tagColor: $0.color)
            }))
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let currentURL { highlight(currentURL) }
        updateTints()
    }

    /// Selects the sidebar entry matching `url` (without navigating), or clears the selection.
    func highlight(_ url: URL) {
        currentURL = url
        suppressSelection = true
        defer { suppressSelection = false }
        for section in sections {
            if let item = section.items.first(where: {
                $0.url.isFileURL == url.isFileURL && ($0.url.isFileURL ? $0.url.standardizedFileURL.path == url.path : $0.url == url)
            }) {
                let row = outlineView.row(forItem: item)
                if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        return (item as? Section)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        return (item as! Section).items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is Item
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? Section {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: section.title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        guard let item = item as? Item else { return nil }
        let cell = NSTableCellView()
        let image = NSImageView(image: item.tagColor.map { FileTags.dotImage(color: $0, size: 14) }
            ?? NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) ?? NSImage())
        if item.tagColor == nil { image.contentTintColor = tint(for: item) }
        let label = NSTextField(labelWithString: item.title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        cell.toolTip = item.toolTip
        for view in [image, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        // Eject button for removable disks and network shares, like Finder
        var trailing = cell.trailingAnchor
        if item.ejectable {
            let eject = SidebarEjectButton(volume: item.url)
            eject.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(eject)
            NSLayoutConstraint.activate([
                eject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                eject.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            trailing = eject.leadingAnchor
        }
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Like Finder: the favourites in the accent colour, places in grey; everything grey while the
    /// window isn't the active one.
    private func tint(for item: Item) -> NSColor {
        let active = view.window?.isKeyWindow ?? true
        let favourite = sections.first { $0.kind == .favorites }?.items.contains { $0 === item } == true
        return active && favourite ? .controlAccentColor : .secondaryLabelColor
    }

    private func updateTints() {
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? Item, item.tagColor == nil,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { continue }
            cell.imageView?.contentTintColor = tint(for: item)
        }
    }

    private let windowObservers = Observers()

    override func viewDidAppear() {
        super.viewDidAppear()
        windowObservers.removeAll()
        guard let window = view.window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.add(name, object: window) { [weak self] in self?.updateTints() }
        }
        updateTints()
    }


    // MARK: - Drag and drop

    private var favoritesSection: Section? { sections.first { $0.kind == .favorites } }

    private func section(of item: Item) -> Section? {
        sections.first { $0.items.contains { $0 === item } }
    }

    /// Favourites are dragged to reorder them.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let item = item as? Item, section(of: item)?.kind == .favorites else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.url.path, forType: Self.favoriteType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let favorites = favoritesSection else { return [] }
        // Reordering the favourites: only between them
        if info.draggingPasteboard.string(forType: Self.favoriteType) != nil {
            if item as? Section === favorites, index >= 0 { return .move }
            if let target = item as? Item, let position = favorites.items.firstIndex(where: { $0 === target }) {
                outlineView.setDropItem(favorites, dropChildIndex: position)
                return .move
            }
            return []
        }
        let urls = FileDrop.urls(info)
        guard !urls.isEmpty else { return [] }
        // Between the favourites: pin the folders there
        if item as? Section === favorites, index >= 0 {
            return urls.allSatisfy(\.isBrowsableDirectory) ? .link : []
        }
        guard let target = item as? Item, index == NSOutlineViewDropOnItemIndex else { return [] }
        return operation(dropping: info, urls: urls, on: target)
    }

    private func operation(dropping info: any NSDraggingInfo, urls: [URL], on target: Item) -> NSDragOperation {
        if target.tagColor != nil { return .copy }  // gets the tag
        if Places.isTrash(target.url) {
            return urls.contains(where: { Places.isTrash($0.deletingLastPathComponent()) }) ? [] : .move
        }
        guard target.action == nil, target.url.isFileURL, target.url.isBrowsableDirectory else { return [] }
        return FileDrop.operation(for: info, into: target.url)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let favorites = favoritesSection else { return false }
        if let path = info.draggingPasteboard.string(forType: Self.favoriteType) {
            SidebarConfig.pin(URL(fileURLWithPath: path), at: favoritesIndex(forChild: index, of: favorites))
            return true
        }
        let urls = FileDrop.urls(info)
        if item as? Section === favorites, index >= 0 {
            var position = favoritesIndex(forChild: index, of: favorites)
            for url in urls {
                let wasBefore = SidebarConfig.favoritePaths.firstIndex(of: url.standardizedFileURL.path).map { $0 < position } ?? false
                SidebarConfig.pin(url, at: position)
                if !wasBefore { position += 1 }
            }
            return true
        }
        guard let target = item as? Item, operation(dropping: info, urls: urls, on: target) != [] else { return false }
        if case .tag(let name) = Location(target.url) {
            FileTags.toggle(FileTags.tag(named: name, knownTags: []), on: urls, add: true)
            NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
            return true
        }
        if Places.isTrash(target.url) {
            FileOps.trash(urls)
            return true
        }
        return FileDrop.perform(info, into: target.url)
    }

    /// A row position among the shown favourites → a position in the stored list (which also
    /// keeps folders that are missing right now).
    private func favoritesIndex(forChild index: Int, of favorites: Section) -> Int {
        let paths = SidebarConfig.favoritePaths
        guard index < favorites.items.count else { return paths.count }
        return paths.firstIndex(of: favorites.items[index].url.path) ?? paths.count
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? Item else { return }
        clickedItem = item
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        // A folder or disk: open it with another app, like in the file list
        if item.url.isFileURL, item.action == nil, !Places.isTrash(item.url), item.url.isBrowsableDirectory {
            if let openWith = OpenWithMenu.item(for: [item.url]) { menu.addItem(openWith) }
            OpenWithMenu.mainMenuItems(for: [item.url]).forEach(menu.addItem)
            if let terminal = TerminalLauncher.menuItem(for: [item.url]) { menu.addItem(terminal) }
            if menu.items.count > 0 { menu.addItem(.separator()) }
        }
        switch section(of: item)?.kind {
        case .favorites:
            add(L("Убрать из боковой панели"), #selector(removeClicked(_:)))
        case .tags:
            add(L("Убрать из боковой панели"), #selector(removeClicked(_:)))
        case .places:
            if item.place == .trash { add(L("Очистить Корзину…"), #selector(emptyTrash(_:))) }
            if let place = item.place {
                add(place == .internalDisks || place == .externalDisks || place == .servers
                    ? L("Скрыть «%@»", place.title) : L("Убрать из боковой панели"), #selector(removeClicked(_:)))
            }
        case nil: break
        }
        menu.addItem(.separator())
        add(L("Настроить боковую панель…"), #selector(customize(_:)))
        MenuStyle.decorate(menu)
    }

    private var clickedItem: Item?

    @objc private func removeClicked(_ sender: Any?) {
        guard let item = clickedItem else { return }
        switch section(of: item)?.kind {
        case .favorites: SidebarConfig.unpin(item.url)
        case .tags:
            TagLibrary.entries = TagLibrary.entries.map { entry in
                var entry = entry
                if entry.name == item.title { entry.inSidebar = false }
                return entry
            }
        case .places: if let place = item.place { SidebarConfig.setShows(place, false) }
        case nil: break
        }
    }

    @objc private func emptyTrash(_ sender: Any?) { Places.emptyTrash() }

    @objc private func customize(_ sender: Any?) {
        AppDelegate.shared.showSettings(tab: .sidebar)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let item = outlineView.item(atRow: outlineView.selectedRow) as? Item else { return }
        if let action = item.action {
            action()
            if let currentURL { highlight(currentURL) }
            return
        }
        onSelect?(item.url)
    }
}

/// "⏏" next to a removable disk or a network share.
private final class SidebarEjectButton: NSButton {
    private let volume: URL

    init(volume: URL) {
        self.volume = volume
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: L("Извлечь"))?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = L("Извлечь")
        target = self
        action = #selector(eject(_:))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func eject(_ sender: Any?) {
        Places.unmount(volume)
    }
}
