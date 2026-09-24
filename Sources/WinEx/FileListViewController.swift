import AppKit

protocol FileListDelegate: AnyObject {
    func fileList(_ list: FileListViewController, open url: URL, in target: FileListViewController.OpenTarget)
    func fileListGoUp(_ list: FileListViewController)
    func fileList(_ list: FileListViewController, didUpdateStatus status: String)
}

/// Table with the contents of the current folder ("Details" view in Windows terms).
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSMenuItemValidation {

    enum OpenTarget { case current, newTab, newWindow }

    weak var delegate: FileListDelegate?
    let tableView = FileTableView()

    private(set) var directory: URL?
    private var allItems: [FileItem] = []
    private var items: [FileItem] = []
    private var watcher: DirectoryWatcher?
    private var errorMessage: String?

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
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        tableView.onOpen = { [weak self] in self?.openSelected(nil) }
        tableView.onGoUp = { [weak self] in
            guard let self else { return }
            self.delegate?.fileListGoUp(self)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        view = scrollView

        NotificationCenter.default.addObserver(forName: .showHiddenChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    // MARK: - Loading

    func load(_ url: URL, select: [URL]) {
        directory = url
        watcher = DirectoryWatcher(url: url) { [weak self] in self?.reload() }
        readDirectory()
        refilter(keepSelection: false)
        let paths = Set(select.map(\.path))
        let rows = IndexSet(items.indices.filter { paths.contains(items[$0].url.path) })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        tableView.scrollRowToVisible(rows.first ?? 0)
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
        tableView.reloadData()
        if keepSelection {
            let rows = IndexSet(items.indices.filter { selectedPaths.contains(items[$0].url.path) })
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        updateStatus()
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
        let selected = tableView.selectedRowIndexes.count
        if selected > 0 { status += "    Выбрано: \(selected)" }
        if let errorMessage { status = "Нет доступа: \(errorMessage)" }
        delegate?.fileList(self, didUpdateStatus: status)
    }

    // MARK: - Selection helpers

    private var selectedURLs: [URL] {
        tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].url : nil }
    }

    /// Rows a context-menu action applies to: the clicked row (and the selection, if it contains it).
    private var targetRows: IndexSet {
        let clicked = tableView.clickedRow
        if clicked >= 0 && !tableView.selectedRowIndexes.contains(clicked) { return IndexSet(integer: clicked) }
        return tableView.selectedRowIndexes
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
        if let row = items.firstIndex(where: { $0.url.path == url.path }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            tableView.editColumn(0, row: row, with: nil, select: true)
        }
    }

    @objc func renameSelected(_ sender: Any?) {
        guard let row = targetRows.first else { return }
        tableView.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func renameEdited(_ sender: NSTextField) {
        let row = tableView.row(for: sender)
        guard items.indices.contains(row) else { return }
        let item = items[row]
        let newName = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name, !newName.contains("/") else {
            sender.stringValue = item.name
            return
        }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            reload()
            if let newRow = items.firstIndex(where: { $0.url.path == destination.path }) {
                tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            }
        } catch {
            sender.stringValue = item.name
            NSAlert(error: error).runModal()
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(moveToTrash(_:)), #selector(openSelected(_:)),
             #selector(renameSelected(_:)), #selector(openInNewTab(_:)), #selector(openInNewWindow(_:)):
            return !targetRows.isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
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
        if tableView.clickedRow >= 0 {
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
            add("Новая папка", #selector(newFolder(_:)))
            add("Вставить", #selector(paste(_:)))
            menu.addItem(.separator())
            add("Копировать путь к папке", #selector(copyPath(_:)))
            add("Обновить", #selector(refresh(_:)))
        }
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
            cell.textField?.stringValue = item.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
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
}

/// Explorer-style keys: Return opens, Backspace goes up a level.
final class FileTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onGoUp: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: onOpen?()   // Return, Enter
        case 51: onGoUp?()       // Backspace
        default: super.keyDown(with: event)
        }
    }
}
