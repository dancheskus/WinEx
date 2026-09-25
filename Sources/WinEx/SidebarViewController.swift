import AppKit

/// Navigation pane: quick access folders and mounted volumes.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Section {
        let title: String
        let items: [Item]
        init(title: String, items: [Item]) { self.title = title; self.items = items }
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
        rebuild()
    }

    private let observers = Observers()

    private func rebuild() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func folder(_ directory: FileManager.SearchPathDirectory, _ symbol: String) -> Item? {
            guard let url = fm.urls(for: directory, in: .userDomainMask).first,
                  fm.fileExists(atPath: url.path) else { return nil }
            return Item(title: url.displayName, url: url, symbol: symbol)
        }
        var quick: [Item?] = [
            Item(title: home.displayName, url: home, symbol: "house"),
            folder(.desktopDirectory, "menubar.dock.rectangle"),
            folder(.documentDirectory, "doc"),
            folder(.downloadsDirectory, "arrow.down.circle"),
            folder(.picturesDirectory, "photo"),
            folder(.musicDirectory, "music.note"),
            folder(.moviesDirectory, "film"),
            Item(title: "Программы", url: URL(fileURLWithPath: "/Applications"), symbol: "square.grid.3x3"),
        ]
        // "Места", like Finder: iCloud Drive, disks and shares, AirDrop, the network, the Trash
        var places: [Item] = [Item(title: "Этот Mac", url: Places.computerURL, symbol: "desktopcomputer")]
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            places.append(Item(title: "iCloud Drive", url: iCloud, symbol: "icloud"))
        }
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
                                      .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey]
        for url in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeLocalizedName ?? url.lastPathComponent
            let item: Item
            if values?.volumeIsLocal == false {
                let server = Places.serverName(ofVolume: url)
                item = Item(title: server.map { "\(name) на \($0)" } ?? name, url: url, symbol: "externaldrive.connected.to.line.below")
                item.toolTip = (try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting?.absoluteString
            } else {
                item = Item(title: name, url: url, symbol: values?.volumeIsInternal ?? true ? "internaldrive" : "externaldrive")
            }
            item.ejectable = !(values?.volumeIsRootFileSystem ?? false)
                && (values?.volumeIsLocal == false || values?.volumeIsEjectable == true || values?.volumeIsRemovable == true)
            places.append(item)
        }
        let airDrop = Item(title: "AirDrop", url: URL(string: "x-winex-airdrop://airdrop")!, symbol: "airplayaudio")
        airDrop.action = { Places.openAirDrop() }
        places.append(airDrop)
        places.append(Item(title: "Сеть", url: Places.networkURL, symbol: "network"))
        places.append(Item(title: "Корзина", url: Places.trashURL, symbol: "trash"))

        sections = [
            Section(title: "Быстрый доступ", items: quick.compactMap { $0 }),
            Section(title: "Места", items: places),
            // Finder's favorite tags; clicking one lists every file with it
            Section(title: "Теги", items: FileTags.favorites.map {
                Item(title: $0.name, url: Location.tagURL($0.name), symbol: "tag", tagColor: $0.color)
            }),
        ]
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let currentURL { highlight(currentURL) }
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
        let favourite = sections.first?.items.contains { $0 === item } == true
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
        image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Извлечь")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = "Извлечь"
        target = self
        action = #selector(eject(_:))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func eject(_ sender: Any?) {
        Places.unmount(volume)
    }
}
