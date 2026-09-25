import AppKit

/// An explorer window: tab strip, navigation bar with an editable path,
/// sidebar, file list and a status bar.
final class ExplorerWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
    NSSearchFieldDelegate, NSSplitViewDelegate, NSMenuItemValidation, FileListDelegate {

    /// Room for the traffic-light buttons to the left of the tab strip.

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
    private let searchField = RoomySearchField()
    private let splitView = NSSplitView()
    private let sidebar = SidebarViewController()
    private let fileList = FileListViewController()
    private let statusLabel = NSTextField(labelWithString: "")
    /// The address bar's capsule (outlined in the accent colour while editing).
    private var addressCapsule = ToolbarCapsule(height: 32, views: [])
    private let breadcrumbs = BreadcrumbBar()
    /// What the status bar says (item count, selection and its size).
    var statusText: String { statusLabel.stringValue }

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
        // An empty unified toolbar: the tall macOS 26 title bar — window buttons with room around
        // them, the modern corner radius. The tabs are drawn in it by WinEx itself.
        let toolbar = NSToolbar(identifier: "WinExWindow")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        buildUI()
        showSelectedTab()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func navButton(_ symbol: String, _ tip: String) -> NSButton {
        let button = NSButton()
        // Grey like Finder's toolbar (the toolbar bezel ignores contentTintColor)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                .applying(.init(hierarchicalColor: .secondaryLabelColor)))
        // Borderless: the capsule around it (ToolbarCapsule) is the shape
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return button
    }

    /// Height of the title bar (the unified toolbar): the tab strip and the sidebar's top fit it.
    private var titleBarHeight: CGFloat {
        guard let window, let content = window.contentView else { return 52 }
        let height = content.frame.height - window.contentLayoutRect.height
        return height > 20 ? height : 52
    }

    /// Where the tab strip starts, in window coordinates (a torn-off tab keeps its grab point).
    var tabBarOriginX: CGFloat {
        window?.layoutIfNeeded()
        return tabBar.convert(NSPoint.zero, to: nil).x
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

        // The capsule around it draws the field (same shape as the search field's)
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.focusRingType = .none
        pathField.controlSize = .extraLarge
        pathField.font = .systemFont(ofSize: 14)
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
        searchField.recentsAutosaveName = "WinExRecentSearches"
        searchField.maximumRecents = 10
        searchField.controlSize = .extraLarge
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 14)
        // Wide like Finder's (up to 300), but never wider than the address bar; both give way in
        // narrow windows down to a usable minimum
        searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let preferred = searchField.widthAnchor.constraint(equalToConstant: 300)
        preferred.priority = .defaultLow + 1
        preferred.isActive = true
        updateSearchMenu()

        setUpViewModeControls()

        // One style for the whole row, sized like the search field: capsules with a light fill
        let height = max(searchField.intrinsicContentSize.height, 32)
        let navGroup = ToolbarCapsule(height: height, views: [backButton, forwardButton, upButton], separators: true)
        // Breadcrumbs normally; the text field while typing a path (same place, one at a time)
        let addressArea = NSView()
        for view in [breadcrumbs, pathField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addressArea.addSubview(view)
        }
        NSLayoutConstraint.activate([
            breadcrumbs.leadingAnchor.constraint(equalTo: addressArea.leadingAnchor, constant: -8),
            breadcrumbs.trailingAnchor.constraint(equalTo: addressArea.trailingAnchor, constant: 8),
            breadcrumbs.topAnchor.constraint(equalTo: addressArea.topAnchor),
            breadcrumbs.bottomAnchor.constraint(equalTo: addressArea.bottomAnchor),
            pathField.leadingAnchor.constraint(equalTo: addressArea.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: addressArea.trailingAnchor),
            pathField.centerYAnchor.constraint(equalTo: addressArea.centerYAnchor),
            addressArea.heightAnchor.constraint(equalToConstant: height),
        ])
        pathField.isHidden = true
        breadcrumbs.onNavigate = { [weak self] url in self?.navigate(to: url) }
        breadcrumbs.onEdit = { [weak self] in self?.focusPathField(nil) }
        addressCapsule = ToolbarCapsule(height: height, views: [addressArea], padding: 14)
        let refreshCapsule = ToolbarCapsule(height: height, views: [refreshButton], round: true)
        let viewCapsule = ToolbarCapsule(height: height, views: [viewModeButton], padding: 6)
        let settingsCapsule = ToolbarCapsule(height: height, views: [settingsButton], round: true)
        let navStack = NSStackView(views: [navGroup, addressCapsule, refreshCapsule, searchField, viewCapsule, settingsCapsule])
        // Both are in the stack now (a constraint between views without a common ancestor throws)
        searchField.widthAnchor.constraint(lessThanOrEqualTo: addressCapsule.widthAnchor).isActive = true
        addressCapsule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        navStack.orientation = .horizontal
        navStack.spacing = 8
        navStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        navStack.alignment = .centerY

        let navBar = NSView()
        navBar.addSubview(navStack)

        let barHeight = titleBarHeight
        sidebar.topInset = barHeight
        sidebar.onSelect = { [weak self] url in
            guard let self else { return }
            navigate(to: url)
            // Like Finder: after picking a place, the keyboard works on its files (⌘V, arrows…)
            self.window?.makeFirstResponder(fileList.focusView)
        }
        fileList.delegate = self
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        // Finder's layout: the sidebar runs the full height (window buttons sit on it); tabs, the
        // navigation row and the files are on the right
        let mainPane = NSView()
        splitView.addArrangedSubview(sidebar.view)
        splitView.addArrangedSubview(mainPane)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let statusBar = NSView()
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(viewModeToggle)

        let topSeparator = NSBox(); topSeparator.boxType = .separator
        let bottomSeparator = NSBox(); bottomSeparator.boxType = .separator

        let fileView = fileList.view
        for view in [tabBar, navBar, navStack, topSeparator, splitView, bottomSeparator, statusBar, statusLabel, viewModeToggle, fileView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        content.addSubview(splitView)
        [tabBar, navBar, topSeparator, fileView, bottomSeparator, statusBar].forEach(mainPane.addSubview)
        // The sidebar's top strip (under the window buttons) drags / zooms the window like a title bar
        let dragArea = WindowDragArea()
        (window as? ExplorerWindow)?.titleBarViews = [tabBar, dragArea]
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dragArea)
        NSLayoutConstraint.activate([
            dragArea.topAnchor.constraint(equalTo: content.topAnchor),
            dragArea.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dragArea.trailingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            dragArea.heightAnchor.constraint(equalToConstant: barHeight),
        ])

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            tabBar.topAnchor.constraint(equalTo: mainPane.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor, constant: 8),
            tabBar.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor, constant: -8),
            tabBar.heightAnchor.constraint(equalToConstant: barHeight),

            navBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            navBar.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 50),
            navStack.leadingAnchor.constraint(equalTo: navBar.leadingAnchor),
            navStack.trailingAnchor.constraint(equalTo: navBar.trailingAnchor),
            navStack.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),

            topSeparator.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),

            fileView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            fileView.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            fileView.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            fileView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: mainPane.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            viewModeToggle.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            viewModeToggle.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        window.layoutIfNeeded()
        splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        // Again once the window is on screen (the first layout can still move the divider)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            applyingSidebarWidth = true
            splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
            applyingSidebarWidth = false
        }
        window.initialFirstResponder = fileList.focusView
    }

    // MARK: - View mode controls

    private func setUpViewModeControls() {
        // Pull-down with every view (Explorer's "View" button)
        // Borderless inside its capsule, with the pull-down arrow
        viewModeButton.isBordered = false
        (viewModeButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtCenter
        viewModeButton.contentTintColor = .secondaryLabelColor
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
        titleItem?.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title)?
            .withSymbolConfiguration(.init(hierarchicalColor: .secondaryLabelColor))
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
        pathField.stringValue = Location(tab.url).addressText
        breadcrumbs.show(Location(tab.url))
        // The field shows the query of a results tab; typing in it refines the search in place
        if case .search(let request) = Location(tab.url) {
            if searchField.stringValue != request.text { searchField.stringValue = request.text }
        } else {
            searchSettle?.cancel()
            searchField.stringValue = ""
        }
        searchField.placeholderString = Settings.searchWholeMac ? "Поиск на Mac" : "Поиск: \(searchFolder.displayName)"
        fileList.load(tab.url, select: tab.pendingSelection)
        tab.pendingSelection = []
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        upButton.isEnabled = tab.canGoUp
        window?.title = tab.title
        sidebar.highlight(tab.url)
        tabBar.reload()
    }

    @objc func connectToServer(_ sender: Any?) {
        NetworkMounter.askAndMount { [weak self] mounted in
            if let mounted { self?.navigate(to: mounted) }
        }
    }

    @objc func goToNetwork(_ sender: Any?) { navigate(to: Places.networkURL) }
    @objc func goToTrash(_ sender: Any?) { navigate(to: Places.trashURL) }
    @objc func openAirDrop(_ sender: Any?) { Places.openAirDrop() }

    func navigate(to url: URL) {
        guard Location(url).isBrowsable else {
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

    /// ⌘L, F4, a click beside the breadcrumbs: type a path (the whole current one selected).
    @objc func focusPathField(_ sender: Any?) {
        breadcrumbs.isHidden = true
        pathField.isHidden = false
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    /// Back to the breadcrumbs once the field lets go.
    private func endAddressEditing() {
        pathField.isHidden = true
        breadcrumbs.isHidden = false
    }

    // MARK: - Search

    private var searchSettle: DispatchWorkItem?

    /// Runs the search a moment after typing stops (each keystroke would start a Spotlight query).
    @objc private func searchChanged(_ sender: NSSearchField) {
        searchSettle?.cancel()
        let text = sender.stringValue
        let work = DispatchWorkItem { [weak self] in self?.search(for: text) }
        searchSettle = work
        // Return (or picking a recent search) searches right away
        let immediate = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 36
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.35), execute: work)
    }

    /// The folder searches start from: the current one, or the one the current results are for.
    private var searchFolder: URL {
        switch Location(selectedTab.url) {
        case .search(let request): request.folder ?? FileManager.default.homeDirectoryForCurrentUser
        case let location: location.directory ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }

    private func search(for rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        let tab = selectedTab
        let current = Location(tab.url)
        guard !text.isEmpty else {
            // Cleared: back to the folder the search was made in
            if case .search(let request) = current {
                if tab.canGoBack { tab.goBack() } else if let folder = request.folder { tab.navigate(to: folder) }
                showSelectedTab()
            }
            return
        }
        let request = SearchRequest(text: text, folder: searchFolder, wholeMac: Settings.searchWholeMac, contents: Settings.searchContents)
        if case .search(let old) = current {
            guard old != request else { return }
            // Refining the query replaces the results; Back still leads to the folder
            tab.replace(with: request.url)
        } else {
            tab.navigate(to: request.url)
        }
        if !searchField.recentSearches.contains(text) {
            searchField.recentSearches = Array(([text] + searchField.recentSearches).prefix(searchField.maximumRecents))
        }
        showSelectedTab()
    }

    // ⌘X / ⌘C / ⌘V wherever the focus is in the window (the sidebar, a button…): the file list
    // isn't in the responder chain then, and the commands would do nothing
    @objc func paste(_ sender: Any?) { fileList.paste(sender) }
    @objc func copy(_ sender: Any?) { fileList.copy(sender) }
    @objc func cut(_ sender: Any?) { fileList.cut(sender) }

    @objc func focusSearchField(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    /// The field's menu: where to search, what to match, recent searches.
    private func updateSearchMenu() {
        let menu = NSMenu()
        func option(_ title: String, _ action: Selector, on: Bool) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
        }
        menu.addItem(.sectionHeader(title: "Где искать"))
        option("В этой папке и вложенных", #selector(searchInFolder(_:)), on: !Settings.searchWholeMac)
        option("На всём Mac", #selector(searchWholeMac(_:)), on: Settings.searchWholeMac)
        menu.addItem(.sectionHeader(title: "Что искать"))
        option("Имена и содержимое", #selector(searchNamesAndContents(_:)), on: Settings.searchContents)
        option("Только имена", #selector(searchNamesOnly(_:)), on: !Settings.searchContents)
        menu.addItem(.separator())
        let title = menu.addItem(withTitle: "Недавние запросы", action: nil, keyEquivalent: "")
        title.tag = NSSearchField.recentsTitleMenuItemTag
        let recent = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        recent.tag = NSSearchField.recentsMenuItemTag
        let none = menu.addItem(withTitle: "Нет недавних запросов", action: nil, keyEquivalent: "")
        none.tag = NSSearchField.noRecentsMenuItemTag
        let clear = menu.addItem(withTitle: "Очистить недавние", action: nil, keyEquivalent: "")
        clear.tag = NSSearchField.clearRecentsMenuItemTag
        searchField.searchMenuTemplate = menu
        // Our own glass + arrow with a gap (the stock one squeezes them together)
        let image = RoomySearchFieldCell.buttonImage(pointSize: 15)
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell?.image = image
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell?.alternateImage = image
    }

    @objc private func searchInFolder(_ sender: Any?) { setSearchOptions(wholeMac: false) }
    @objc private func searchWholeMac(_ sender: Any?) { setSearchOptions(wholeMac: true) }
    @objc private func searchNamesAndContents(_ sender: Any?) { setSearchOptions(contents: true) }
    @objc private func searchNamesOnly(_ sender: Any?) { setSearchOptions(contents: false) }

    /// Changing an option re-runs the current search with it.
    private func setSearchOptions(wholeMac: Bool? = nil, contents: Bool? = nil) {
        if let wholeMac { Settings.searchWholeMac = wholeMac }
        if let contents { Settings.searchContents = contents }
        updateSearchMenu()
        searchField.placeholderString = Settings.searchWholeMac ? "Поиск на Mac" : "Поиск: \(searchFolder.displayName)"
        if case .search = Location(selectedTab.url) { search(for: searchField.stringValue) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paste(_:)), #selector(copy(_:)), #selector(cut(_:)): return fileList.validateMenuItem(menuItem)
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
        // Esc in the search field: drop the search (back to the folder) and leave the field
        if control === searchField, selector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.stringValue = ""
            search(for: "")
            window?.makeFirstResponder(fileList.focusView)
            return true
        }
        guard control === pathField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitPath()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            pathField.stringValue = Location(selectedTab.url).addressText
            window?.makeFirstResponder(fileList.focusView)
            return true
        default:
            return false
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === pathField { addressCapsule.isFocused = true }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pathField else { return }
        addressCapsule.isFocused = false
        endAddressEditing()
        pathField.stringValue = Location(selectedTab.url).addressText
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

    // MARK: - Shortcuts from Windows

    /// Keys handled before the focused view sees them. Always: ⌃Tab / ⌃⇧Tab switch tabs, ⌃1…9
    /// picks a tab. With "Клавиши как в Windows": F3 search, F4 / ⌥D address bar, F5 refresh,
    /// F11 full screen, Delete → Trash, ⇧Delete → delete for good, ⌥← ⌥→ ⌥↑ back / forward / up,
    /// ⇧F10 context menu. Keys that edit text (arrows, Delete, ⌥D) are left to text fields.
    func handleShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let typing = window?.firstResponder is NSTextView
        switch (event.keyCode, modifiers) {
        case (48, [.control]): selectNextTab(nil); return true                       // ⌃Tab
        case (48, [.control, .shift]): selectPreviousTab(nil); return true           // ⌃⇧Tab
        case (_, [.control]) where Int(event.charactersIgnoringModifiers ?? "").map({ (1...9).contains($0) }) == true:
            guard let number = Int(event.charactersIgnoringModifiers ?? "") else { return false }
            // ⌃9 is the last tab, like in browsers
            selectTab(at: number == 9 ? tabs.count - 1 : min(number - 1, tabs.count - 1))
            return true
        default: break
        }
        guard Settings.windowsKeys else { return false }
        switch (event.keyCode, modifiers) {
        case (99, []): focusSearchField(nil)                                          // F3
        case (118, []): focusPathField(nil)                                           // F4
        case (96, []): refresh(nil)                                                   // F5
        case (103, []): window?.toggleFullScreen(nil)                                 // F11
        case (109, [.shift]): fileList.showContextMenuForSelection()                  // ⇧F10
        case (2, [.option]) where !typing: focusPathField(nil)                        // ⌥D
        case (123, [.option]) where !typing: goBack(nil)                              // ⌥←
        case (124, [.option]) where !typing: goForward(nil)                           // ⌥→
        case (126, [.option]) where !typing: goUp(nil)                                // ⌥↑
        case (117, []) where !typing: fileList.moveToTrash(nil)                       // Delete
        case (117, [.shift]) where !typing: fileList.deleteSelectedForever()          // ⇧Delete
        default: return false
        }
        return true
    }

    // MARK: - FileListDelegate

    func fileList(_ list: FileListViewController, open url: URL, in target: FileListViewController.OpenTarget) {
        // A server in "Сеть": mount it (system login / share picker), then show the share
        if Places.isServer(url) {
            NetworkMounter.mount(url) { [weak self] mounted in
                guard let self, let mounted else { return }
                self.fileList(list, open: mounted, in: target)
            }
            return
        }
        // An alias opens what it points to; a ZIP is extracted next to itself, like Finder
        let url = FileCommands.resolved(url)
        if FileCommands.isZip(url), target == .current {
            FileCommands.extract(url)
            return
        }
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

    /// "Показать в папке" for a search result: its folder, with it selected.
    func fileList(_ list: FileListViewController, reveal url: URL) {
        selectedTab.pendingSelection = [url]
        navigate(to: url.deletingLastPathComponent())
    }

    func fileList(_ list: FileListViewController, browse package: URL) {
        browse(package)
    }

    /// Shows a package (an app, a bundle) as a folder — `navigate` would open it.
    func browse(_ package: URL) {
        selectedTab.navigate(to: package)
        showSelectedTab()
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

    /// The sidebar's width: what the user last dragged it to (200 pt at first), for every window.
    static var sidebarWidth: CGFloat {
        get { CGFloat(AppDefaults.store.object(forKey: "sidebarWidth") as? Double ?? 200) }
        set { AppDefaults.store.set(Double(newValue), forKey: "sidebarWidth") }
    }

    private var applyingSidebarWidth = false

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only the user's drag counts (not window resizing or the initial layout)
        guard !applyingSidebarWidth, NSApp.currentEvent?.type == .leftMouseDragged else { return }
        Self.sidebarWidth = sidebar.view.frame.width
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        150
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        400
    }

    // MARK: - NSWindowDelegate

    // Where the next window opens when none is open: the window moved, resized or closed last.
    // (Not "became active": closing a window activates another one by itself.)
    func windowDidMove(_ notification: Notification) { rememberPlacement() }
    func windowDidEndLiveResize(_ notification: Notification) { rememberPlacement() }
    func windowDidResize(_ notification: Notification) { if window?.inLiveResize == false { rememberPlacement() } }  // zoom
    func windowDidExitFullScreen(_ notification: Notification) { rememberPlacement() }

    private func rememberPlacement() {
        if let window { WindowPlacement.remember(window) }
    }

    func windowWillClose(_ notification: Notification) {
        if !AppDelegate.shared.isTerminating { rememberPlacement() }
        fileList.stopWatching()
        AppDelegate.shared.windowControllerDidClose(self)
    }
}

/// Address bar: the first click selects the whole path, like a browser's address bar.
/// Clicks while already editing place the caret as usual.
final class AddressField: NSTextField {
    /// When this field last became the first responder (system uptime). The window does that
    /// while handling the mouse-down, before `mouseDown` runs — so "was it editing already?"
    /// can't be asked there, only "did the focus arrive with this very click?".
    private var focusedAt: TimeInterval = 0

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        focusedAt = ProcessInfo.processInfo.systemUptime
        return true
    }

    /// The click that focuses the field selects the whole path, like a browser's address bar.
    /// `super.mouseDown` returns once the click is over (the field editor tracks it until the
    /// button goes up), so this runs after the caret was placed — a deferred selectAll could run
    /// while the button was still down and be undone by the mouse-up.
    override func mouseDown(with event: NSEvent) {
        let sinceClick = focusedAt - event.timestamp
        let focusing = sinceClick >= 0 && sinceClick < 0.5
        focusedAt = 0
        super.mouseDown(with: event)
        // A drag that selected part of the path keeps its selection
        guard focusing, let editor = currentEditor(), editor.selectedRange.length == 0 else { return }
        editor.selectAll(nil)
    }
}

/// Clicks in the title bar area normally go to the (invisible) title bar view, not to the tab strip
/// drawn there. This window hands them to our title bar views directly; traffic lights keep theirs.
final class ExplorerWindow: NSWindow {
    var titleBarViews: [NSView] = []

    /// When a window is shown, AppKit may constrain it to the "current" monitor (the one with the
    /// Dock click or the active desktop) and pull a window restored on another monitor over to it.
    /// Constrain to the monitor the window is actually on instead.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        super.constrainFrameRect(frameRect, to: Self.screen(containing: frameRect) ?? screen)
    }

    /// The monitor showing the largest part of `rect`, if any part is visible.
    static func screen(containing rect: NSRect) -> NSScreen? {
        func area(_ screen: NSScreen) -> CGFloat {
            let overlap = screen.frame.intersection(rect)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let best = NSScreen.screens.max(by: { area($0) < area($1) }), area(best) > 0 else { return nil }
        return best
    }

    /// One file-operation history for all windows and the desktop. NSWindow's own undo:/redo:
    /// use its internal manager, so they are answered here explicitly (text fields handle their own first).
    override var undoManager: UndoManager? { FileUndo.manager(for: self) }
    @objc func undo(_ sender: Any?) { FileUndo.manager(for: self).undo() }
    @objc func redo(_ sender: Any?) { FileUndo.manager(for: self).redo() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        FileUndo.validate(menuItem, in: self) ?? super.validateMenuItem(menuItem)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let controller = windowController as? ExplorerWindowController,
           controller.handleShortcut(event) { return }
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

/// The search field with room between the magnifying glass and the arrow of its menu.
final class RoomySearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { RoomySearchFieldCell.self }
        set {}
    }
}

final class RoomySearchFieldCell: NSSearchFieldCell {
    private static let gap: CGFloat = 8

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        var button = super.searchButtonRect(forBounds: rect)
        button.size.width += Self.gap
        return button
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var text = super.searchTextRect(forBounds: rect)
        text.origin.x += Self.gap
        text.size.width -= Self.gap
        return text
    }

    /// Magnifying glass, a gap, then the small arrow that opens the menu.
    static func buttonImage(pointSize: CGFloat) -> NSImage {
        let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Поиск")?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) ?? NSImage()
        let arrow = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize * 0.55, weight: .semibold)) ?? NSImage()
        let spacing: CGFloat = 5
        let size = NSSize(width: glass.size.width + spacing + arrow.size.width, height: max(glass.size.height, arrow.size.height))
        let image = NSImage(size: size, flipped: false) { rect in
            glass.draw(in: NSRect(x: 0, y: (rect.height - glass.size.height) / 2, width: glass.size.width, height: glass.size.height))
            arrow.draw(in: NSRect(x: glass.size.width + spacing, y: (rect.height - arrow.size.height) / 2,
                                  width: arrow.size.width, height: arrow.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The toolbar's one shape: a capsule with a light fill and a hairline, as tall as the search
/// field. Holds borderless buttons (with thin separators between them) or the address field.
final class ToolbarCapsule: NSView {
    var isFocused = false { didSet { needsDisplay = true } }
    private let round: Bool

    init(height: CGFloat, views: [NSView], separators: Bool = false, padding: CGFloat = 0, round: Bool = false) {
        self.round = round
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        if round { widthAnchor.constraint(equalToConstant: height).isActive = true }
        var arranged: [NSView] = []
        for (n, view) in views.enumerated() {
            if separators && n > 0 {
                let line = ColorView()
                line.color = .separatorColor
                line.translatesAutoresizingMaskIntoConstraints = false
                line.widthAnchor.constraint(equalToConstant: 1).isActive = true
                line.heightAnchor.constraint(equalToConstant: height * 0.5).isActive = true
                arranged.append(line)
            }
            arranged.append(view)
        }
        let stack = NSStackView(views: arranged)
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in views where view is NSButton { view.heightAnchor.constraint(equalTo: heightAnchor).isActive = true }
        if round, let only = views.first { only.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        shape.fill()
        (isFocused ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.12)).setStroke()
        shape.lineWidth = isFocused ? 2 : 1
        shape.stroke()
    }
}
