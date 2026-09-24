import AppKit

/// An explorer window: tab strip, navigation bar with an editable path,
/// sidebar, file list and a status bar.
final class ExplorerWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
    NSSplitViewDelegate, NSMenuItemValidation, FileListDelegate {

    /// Room for the traffic-light buttons to the left of the tab strip.
    static let tabBarLeadingInset: CGFloat = 78

    private(set) var tabs: [ExplorerTab]
    private(set) var selectedIndex = 0
    var selectedTab: ExplorerTab { tabs[selectedIndex] }

    let tabBar = TabBarView()
    private let backButton = ExplorerWindowController.navButton("arrow.left", "Назад (⌘[)")
    private let forwardButton = ExplorerWindowController.navButton("arrow.right", "Вперёд (⌘])")
    private let upButton = ExplorerWindowController.navButton("arrow.up", "Вверх (⌘↑)")
    private let refreshButton = ExplorerWindowController.navButton("arrow.clockwise", "Обновить (⌘R)")
    private let settingsButton = ExplorerWindowController.navButton("gearshape", "Настройки")
    private let pathField = AddressField()
    private let viewModeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let viewModeToggle = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let splitView = NSSplitView()
    private let sidebar = SidebarViewController()
    private let fileList = FileListViewController()
    private let statusLabel = NSTextField(labelWithString: "")

    init(tabs: [ExplorerTab]) {
        precondition(!tabs.isEmpty)
        self.tabs = tabs
        let window = ExplorerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // The tab strip lives in the title bar area. If the window server may move the window, it
        // grabs every drag there (tabs included) before AppKit sees it — so we move the window ourselves.
        window.isMovable = false
        // The Dock menu lists folders (tabs included) itself; keep the system's per-window list out of it
        window.isExcludedFromWindowsMenu = true
        window.minSize = NSSize(width: 640, height: 360)
        // Tab strip color; the selected tab and the nav bar use controlBackgroundColor
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.07, alpha: 1) : NSColor(white: 0.85, alpha: 1)
        }
        super.init(window: window)
        window.delegate = self
        buildUI()
        showSelectedTab()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func navButton(_ symbol: String, _ tip: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        tabBar.controller = self

        backButton.target = self; backButton.action = #selector(goBack(_:))
        forwardButton.target = self; forwardButton.action = #selector(goForward(_:))
        upButton.target = self; upButton.action = #selector(goUp(_:))
        refreshButton.target = self; refreshButton.action = #selector(refresh(_:))
        settingsButton.target = AppDelegate.shared; settingsButton.action = #selector(AppDelegate.showSettings(_:))

        pathField.bezelStyle = .roundedBezel
        pathField.font = .systemFont(ofSize: 13)
        pathField.usesSingleLineMode = true
        pathField.cell?.isScrollable = true
        pathField.cell?.wraps = false
        pathField.lineBreakMode = .byTruncatingHead
        pathField.placeholderString = "Путь к папке"
        pathField.delegate = self
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        setUpViewModeControls()

        let navStack = NSStackView(views: [backButton, forwardButton, upButton, pathField, refreshButton, searchField, viewModeButton, settingsButton])
        navStack.orientation = .horizontal
        navStack.spacing = 4
        navStack.setCustomSpacing(10, after: upButton)
        navStack.setCustomSpacing(10, after: refreshButton)
        navStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        navStack.alignment = .centerY

        let navBar = ColorView()
        navBar.color = .controlBackgroundColor
        navBar.addSubview(navStack)

        sidebar.onSelect = { [weak self] url in self?.navigate(to: url) }
        fileList.delegate = self
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebar.view)
        splitView.addArrangedSubview(fileList.view)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let statusBar = ColorView()
        statusBar.color = .controlBackgroundColor
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(viewModeToggle)

        let topSeparator = NSBox(); topSeparator.boxType = .separator
        let bottomSeparator = NSBox(); bottomSeparator.boxType = .separator

        for view in [tabBar, navBar, navStack, topSeparator, splitView, bottomSeparator, statusBar, statusLabel, viewModeToggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        [tabBar, navBar, topSeparator, splitView, bottomSeparator, statusBar].forEach(content.addSubview)
        // Title bar strip left of the tabs (under the traffic lights) still drags / zooms the window
        let dragArea = WindowDragArea()
        (window as? ExplorerWindow)?.titleBarViews = [tabBar, dragArea]
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dragArea, positioned: .below, relativeTo: tabBar)
        NSLayoutConstraint.activate([
            dragArea.topAnchor.constraint(equalTo: content.topAnchor),
            dragArea.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dragArea.trailingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            dragArea.heightAnchor.constraint(equalToConstant: TabBarView.height),
        ])

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.tabBarLeadingInset),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),

            navBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            navBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 40),
            navStack.leadingAnchor.constraint(equalTo: navBar.leadingAnchor),
            navStack.trailingAnchor.constraint(equalTo: navBar.trailingAnchor),
            navStack.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),

            topSeparator.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            viewModeToggle.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            viewModeToggle.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        window.layoutIfNeeded()
        splitView.setPosition(210, ofDividerAt: 0)
        window.initialFirstResponder = fileList.focusView
    }

    // MARK: - View mode controls

    private func setUpViewModeControls() {
        // Pull-down with every view (Explorer's "View" button)
        viewModeButton.bezelStyle = .accessoryBarAction
        viewModeButton.isBordered = false
        viewModeButton.toolTip = "Вид"
        let menu = viewModeButton.menu!
        menu.addItem(NSMenuItem())  // title item of a pull-down: shows the current view's icon
        for mode in ViewMode.allCases {
            let item = menu.addItem(withTitle: mode.title, action: #selector(selectViewMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Применить ко всем папкам", action: #selector(applyViewModeToAllFolders(_:)), keyEquivalent: "").target = self

        // Two quick toggles in the status bar, like Explorer's bottom-right corner
        viewModeToggle.segmentCount = 2
        viewModeToggle.trackingMode = .selectOne
        viewModeToggle.segmentStyle = .texturedRounded
        viewModeToggle.controlSize = .small
        viewModeToggle.setImage(NSImage(systemSymbolName: ViewMode.details.symbol, accessibilityDescription: "Таблица"), forSegment: 0)
        viewModeToggle.setImage(NSImage(systemSymbolName: ViewMode.largeIcons.symbol, accessibilityDescription: "Крупные значки"), forSegment: 1)
        viewModeToggle.setToolTip("Таблица", forSegment: 0)
        viewModeToggle.setToolTip("Крупные значки", forSegment: 1)
        viewModeToggle.target = self
        viewModeToggle.action = #selector(viewModeToggleChanged(_:))
    }

    private func updateViewModeControls() {
        let mode = fileList.viewMode
        let titleItem = viewModeButton.menu?.items.first
        titleItem?.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title)
        titleItem?.title = ""
        for item in viewModeButton.menu?.items.dropFirst() ?? [] where item.action == #selector(selectViewMode(_:)) {
            item.state = item.tag == mode.rawValue ? .on : .off
        }
        viewModeToggle.selectedSegment = mode == .details ? 0 : (mode == .largeIcons ? 1 : -1)
    }

    @objc func selectViewMode(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let mode = ViewMode(rawValue: tag) else { return }
        fileList.viewMode = mode
    }

    @objc private func applyViewModeToAllFolders(_ sender: Any?) {
        fileList.applyViewModeToAllFolders()
    }

    @objc private func viewModeToggleChanged(_ sender: NSSegmentedControl) {
        fileList.viewMode = sender.selectedSegment == 0 ? .details : .largeIcons
    }

    // MARK: - Showing the current tab

    private func showSelectedTab() {
        let tab = selectedTab
        // Leaving the address bar mid-edit (tab switch, sidebar click…) drops the edit and its selection
        if pathField.currentEditor() != nil { window?.makeFirstResponder(fileList.focusView) }
        pathField.stringValue = tab.url.path
        searchField.stringValue = ""
        searchField.placeholderString = "Поиск: \(tab.title)"
        fileList.load(tab.url, select: tab.pendingSelection)
        tab.pendingSelection = []
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        upButton.isEnabled = tab.canGoUp
        window?.title = tab.title
        sidebar.highlight(tab.url)
        tabBar.reload()
    }

    func navigate(to url: URL) {
        guard url.isBrowsableDirectory else {
            NSWorkspace.shared.open(url)
            return
        }
        selectedTab.navigate(to: url)
        showSelectedTab()
    }

    // MARK: - Tabs

    func selectTab(at index: Int) {
        guard index != selectedIndex, tabs.indices.contains(index) else { return }
        selectedIndex = index
        showSelectedTab()
    }

    func addTab(url: URL, select: Bool = true) {
        tabs.insert(ExplorerTab(url: url), at: selectedIndex + 1)
        if select {
            selectedIndex += 1
            showSelectedTab()
        } else {
            tabBar.reload()
        }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs.count == 1 {
            window?.close()
            return
        }
        let wasSelected = index == selectedIndex
        tabs.remove(at: index)
        if index < selectedIndex || selectedIndex >= tabs.count { selectedIndex -= 1 }
        if wasSelected { showSelectedTab() } else { tabBar.reload() }
    }

    func moveTab(from source: Int, to destination: Int) {
        let selected = selectedTab
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        selectedIndex = tabs.firstIndex { $0 === selected } ?? 0
        tabBar.reload()
    }

    /// Removes the tab and opens it in a new window of the same size. Returns that window.
    func detachTab(at index: Int) -> NSWindow {
        let tab = tabs[index]
        closeTab(at: index)
        let size = window?.frame.size ?? NSSize(width: 1000, height: 640)
        let controller = AppDelegate.shared.openWindow(with: [tab], origin: .zero)
        controller.window?.setFrame(NSRect(origin: .zero, size: size), display: true)
        return controller.window!
    }

    func insertTabs(_ newTabs: [ExplorerTab], at index: Int) {
        let index = min(max(index, 0), tabs.count)
        tabs.insert(contentsOf: newTabs, at: index)
        selectedIndex = index
        showSelectedTab()
    }

    // MARK: - Actions

    @objc func newTab(_ sender: Any?) {
        addTab(url: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        closeTab(at: selectedIndex)
    }

    @objc func selectNextTab(_ sender: Any?) {
        selectTab(at: (selectedIndex + 1) % tabs.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        selectTab(at: (selectedIndex - 1 + tabs.count) % tabs.count)
    }

    @objc func goBack(_ sender: Any?) {
        selectedTab.goBack()
        showSelectedTab()
    }

    @objc func goForward(_ sender: Any?) {
        selectedTab.goForward()
        showSelectedTab()
    }

    @objc func goUp(_ sender: Any?) {
        selectedTab.goUp()
        showSelectedTab()
    }

    @objc func refresh(_ sender: Any?) {
        fileList.reload()
    }

    @objc func focusPathField(_ sender: Any?) {
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        fileList.filter = sender.stringValue
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return selectedTab.canGoBack
        case #selector(goForward(_:)): return selectedTab.canGoForward
        case #selector(goUp(_:)): return selectedTab.canGoUp
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): return tabs.count > 1
        case #selector(selectViewMode(_:)):
            menuItem.state = menuItem.tag == fileList.viewMode.rawValue ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: - Path field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === pathField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitPath()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            pathField.stringValue = selectedTab.url.path
            window?.makeFirstResponder(fileList.focusView)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pathField else { return }
        pathField.stringValue = selectedTab.url.path
    }

    /// Accepts "/path", "~/path" and "file:///path". A file path reveals the file in its folder.
    private func commitPath() {
        let raw = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            path = url.path
        } else {
            path = (raw as NSString).expandingTildeInPath
        }
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        let url = URL(fileURLWithPath: path)
        window?.makeFirstResponder(fileList.focusView)
        if url.isBrowsableDirectory {
            navigate(to: url)
        } else {
            selectedTab.pendingSelection = [url]
            selectedTab.navigate(to: url.deletingLastPathComponent())
            showSelectedTab()
        }
    }

    // MARK: - FileListDelegate

    func fileList(_ list: FileListViewController, open url: URL, in target: FileListViewController.OpenTarget) {
        guard url.isBrowsableDirectory else {
            NSWorkspace.shared.open(url)
            return
        }
        switch target {
        case .current: navigate(to: url)
        case .newTab: addTab(url: url, select: false)
        case .newWindow: AppDelegate.shared.openWindow(at: url)
        }
    }

    func fileListGoUp(_ list: FileListViewController) {
        goUp(nil)
    }

    func fileList(_ list: FileListViewController, didUpdateStatus status: String) {
        statusLabel.stringValue = status
    }

    func fileList(_ list: FileListViewController, didChangeViewMode mode: ViewMode) {
        updateViewModeControls()
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        150
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        400
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        fileList.stopWatching()
        AppDelegate.shared.windowControllerDidClose(self)
    }
}

/// Address bar: the first click selects the whole path, like a browser's address bar.
/// Clicks while already editing place the caret as usual.
final class AddressField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        // The click that focused us is still being tracked by the field editor and will place
        // the caret; select everything once it's done, unless the user dragged out a selection.
        DispatchQueue.main.async { [weak self] in
            guard let editor = self?.currentEditor(), editor.selectedRange.length == 0 else { return }
            editor.selectAll(nil)
        }
        return true
    }
}

/// Clicks in the title bar area normally go to the (invisible) title bar view, not to the tab strip
/// drawn there. This window hands them to our title bar views directly; traffic lights keep theirs.
final class ExplorerWindow: NSWindow {
    var titleBarViews: [NSView] = []

    override func sendEvent(_ event: NSEvent) {
        let routed: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .otherMouseUp]
        guard routed.contains(event.type), let target = titleBarTarget(for: event) else {
            return super.sendEvent(event)
        }
        switch event.type {
        case .leftMouseDown: target.mouseDown(with: event)
        case .rightMouseDown: target.rightMouseDown(with: event)
        case .otherMouseDown: target.otherMouseDown(with: event)
        default: target.otherMouseUp(with: event)
        }
    }

    private func titleBarTarget(for event: NSEvent) -> NSView? {
        let point = event.locationInWindow
        // Leave the close / minimize / zoom buttons alone
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(kind), !button.isHidden,
               button.convert(button.bounds, to: nil).contains(point) { return nil }
        }
        for view in titleBarViews where !view.isHidden {
            guard let superview = view.superview else { continue }
            let local = superview.convert(point, from: nil)
            if view.frame.contains(local) { return view.hitTest(local) ?? view }
        }
        return nil
    }
}
