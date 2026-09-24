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
        init(title: String, url: URL, symbol: String) { self.title = title; self.url = url; self.symbol = symbol }
    }

    var onSelect: ((URL) -> Void)?

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
        outlineView.rowSizeStyle = .default
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
            scrollView.topAnchor.constraint(equalTo: background.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        view = background

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
        rebuild()
    }

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
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            quick.append(Item(title: "iCloud Drive", url: iCloud, symbol: "icloud"))
        }

        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey]
        let volumes = (fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .map { url -> Item in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isInternal = values?.volumeIsInternal ?? true
                return Item(title: values?.volumeLocalizedName ?? url.lastPathComponent, url: url,
                            symbol: isInternal ? "internaldrive" : "externaldrive")
            }

        sections = [
            Section(title: "Быстрый доступ", items: quick.compactMap { $0 }),
            Section(title: "Этот Mac", items: volumes),
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
            if let item = section.items.first(where: { $0.url.standardizedFileURL.path == url.path }) {
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
        let image = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: item.title)
        label.lineBreakMode = .byTruncatingTail
        for view in [image, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let item = outlineView.item(atRow: outlineView.selectedRow) as? Item else { return }
        onSelect?(item.url)
    }
}
