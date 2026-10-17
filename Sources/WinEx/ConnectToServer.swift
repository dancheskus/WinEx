import AppKit

/// "Подключение к серверу" (⌘K), like Finder's: an address with the recent ones in its list,
/// the favourite servers (+ adds the address, − removes the chosen one; double-click connects),
/// «Просмотреть» shows "Сеть" and leaves this window open. An ordinary window: it closes on
/// «Подключиться» or Esc. Finder's own favourites are closed to other apps by macOS, so
/// WinEx keeps its own list.
@MainActor
final class ConnectToServerWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSComboBoxDelegate {
    /// The one window (⌘K again brings it forward).
    private(set) static var shared: ConnectToServerWindow?

    /// Shows the window; `onConnect` gets the address chosen.
    static func show(onConnect: @escaping @MainActor (String) -> Void) {
        let controller = shared ?? ConnectToServerWindow()
        shared = controller
        controller.onConnect = onConnect
        if controller.window?.isVisible != true { controller.window?.center() }
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Lists

    private static let favoritesKey = "favoriteServers"
    private static let recentKey = "recentServers"

    static var favorites: [String] {
        get { AppDefaults.store.stringArray(forKey: favoritesKey) ?? [] }
        set { AppDefaults.store.set(newValue, forKey: favoritesKey) }
    }

    /// The last addresses connected to, newest first (the one before this list existed included).
    static var recent: [String] {
        get {
            AppDefaults.store.stringArray(forKey: recentKey)
                ?? AppDefaults.store.string(forKey: "lastServerAddress").map { [$0] } ?? []
        }
        set { AppDefaults.store.set(Array(newValue.prefix(10)), forKey: recentKey) }
    }

    static func remember(_ address: String) {
        recent = [address] + recent.filter { $0.caseInsensitiveCompare(address) != .orderedSame }
    }

    /// "nas.local" → "smb://nas.local", as Finder takes it.
    static func normalized(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.contains("://") ? text : "smb://" + text
    }

    // MARK: Window

    private var onConnect: (@MainActor (String) -> Void)?
    private let address = NSComboBox()
    private let table = NSTableView()
    private let addRemove = NSSegmentedControl()
    private let connectButton = NSButton(title: L("Подключиться"), target: nil, action: nil)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 290),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Подключение к серверу")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build(in: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(in window: NSWindow) {
        guard let content = window.contentView else { return }
        address.completes = true
        address.numberOfVisibleItems = 10
        address.addItems(withObjectValues: Self.recent)
        address.stringValue = Self.recent.first ?? "smb://"
        address.placeholderString = L("Например: smb://NAS.local или afp://192.168.1.10/Share")
        address.target = self
        address.action = #selector(addressChanged(_:))
        address.delegate = self

        let title = NSTextField(labelWithString: L("Избранные серверы:"))
        title.font = .systemFont(ofSize: 13, weight: .medium)

        let column = NSTableColumn(identifier: .init("address"))
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectFavorite(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        addRemove.segmentCount = 2
        addRemove.trackingMode = .momentary
        addRemove.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: L("Добавить")), forSegment: 0)
        addRemove.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: L("Удалить")), forSegment: 1)
        addRemove.setToolTip(L("Добавить адрес в избранное"), forSegment: 0)
        addRemove.setToolTip(L("Убрать выбранный сервер из избранного"), forSegment: 1)
        addRemove.target = self
        addRemove.action = #selector(addOrRemove(_:))

        let browse = NSButton(title: L("Просмотреть"), target: self, action: #selector(browse(_:)))
        browse.toolTip = L("Серверы в сети («Сеть»)")
        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        connectButton.keyEquivalent = "\r"

        for view in [address, title, scroll, addRemove, browse, connectButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            address.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            address.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            address.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: address.bottomAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: address.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: address.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: address.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: addRemove.topAnchor, constant: -10),
            addRemove.leadingAnchor.constraint(equalTo: address.leadingAnchor),
            addRemove.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            connectButton.trailingAnchor.constraint(equalTo: address.trailingAnchor),
            connectButton.centerYAnchor.constraint(equalTo: addRemove.centerYAnchor),
            browse.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -8),
            browse.centerYAnchor.constraint(equalTo: addRemove.centerYAnchor),
        ])
        window.initialFirstResponder = address
        updateButtons()
    }

    private func updateButtons() {
        connectButton.isEnabled = URL(string: Self.normalized(address.stringValue))?.host != nil
        addRemove.setEnabled(connectButton.isEnabled, forSegment: 0)
        addRemove.setEnabled(table.selectedRow >= 0, forSegment: 1)
    }

    private func connect(to text: String) {
        window?.close()
        onConnect?(text)
    }

    // MARK: Actions

    @objc private func addressChanged(_ sender: Any?) { updateButtons() }

    func controlTextDidChange(_ notification: Notification) { updateButtons() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.updateButtons() }
    }

    @objc private func connect(_ sender: Any?) {
        let text = Self.normalized(address.stringValue)
        guard URL(string: text)?.host != nil else { return NSSound.beep() }
        connect(to: text)
    }

    @objc private func connectFavorite(_ sender: Any?) {
        guard Self.favorites.indices.contains(table.clickedRow) else { return }
        connect(to: Self.favorites[table.clickedRow])
    }

    /// "Сеть": the window already showing it comes forward, else a new one opens; this one stays.
    @objc private func browse(_ sender: Any?) {
        if let shown = AppDelegate.shared.windowControllers.first(where: { $0.selectedTab.location == .network }) {
            shown.window?.makeKeyAndOrderFront(nil)
        } else {
            _ = AppDelegate.shared.openWindow(at: Places.networkURL)
        }
        window?.orderFront(nil)
    }

    /// Esc closes it, as any window of this kind.
    override func cancelOperation(_ sender: Any?) { window?.close() }

    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            let text = Self.normalized(address.stringValue)
            guard URL(string: text)?.host != nil else { return NSSound.beep() }
            if !Self.favorites.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) { Self.favorites.append(text) }
        } else if Self.favorites.indices.contains(table.selectedRow) {
            Self.favorites.remove(at: table.selectedRow)
        }
        table.reloadData()
        updateButtons()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { Self.favorites.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: Self.favorites.indices.contains(row) ? Self.favorites[row] : "")
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if Self.favorites.indices.contains(table.selectedRow) { address.stringValue = Self.favorites[table.selectedRow] }
        updateButtons()
    }
}
