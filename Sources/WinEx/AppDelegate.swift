import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var windowControllers: [ExplorerWindowController] = []
    private var statusItem: NSStatusItem!
    private var settingsController: SettingsWindowController?
    private var desktop: DesktopController?
    private var openedByEvent = false
    private var launchedAtLogin = false

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Read now: the launch Apple event is only "current" during launch
        launchedAtLogin = LoginItem.launchedAtLogin()
        NSApp.mainMenu = MainMenu.build()
        // "Reveal in file viewer" ('misc'/'mvis') — sent to the NSFileViewer app
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleRevealEvent(_:withReply:)),
            forEventClass: fourCC("misc"), andEventID: fourCC("mvis"))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SetupWizard.markExistingUser()
        setupStatusItem()

        #if DEBUG
        Scenario.startIfRequested()
        #endif
        if Settings.replaceFinder { enableFinderReplacement() }
        #if DEBUG
        // Scenario runs must not take the shortcut from the user's WinEx
        if !Scenario.isRequested {
            GlobalHotKey.shared.apply()
            Updater.shared.startAutomaticChecks()
        }
        #else
        GlobalHotKey.shared.apply()
        Updater.shared.startAutomaticChecks()
        #endif
        // Tags already on files join the sidebar's list (one quick Spotlight query)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { TagLibrary.discover() }
        // Back from a restart (a new language): the same windows as before
        let restored = restoreSession()
        // The first launch (or back to the assistant after a restart it asked for)
        if SetupWizard.shouldShow { SetupWizard.show(); return }
        if restored { return }
        // At login WinEx starts quietly (desktop + menu bar); a normal launch opens a window
        if !openedByEvent && !launchedAtLogin { openWindow(at: Settings.startURL) }
    }

    // MARK: - Restart with the same windows

    private static let sessionKey = "restartSession"

    /// Quits and starts again with the same windows (their tabs, the current tab, the frames)
    /// and, if asked, the settings — for a new language.
    func restartKeepingWindows(settingsOpen: Bool) {
        saveSession(settingsOpen: settingsOpen)
        Updater.shared.restart()
    }

    func saveSession(settingsOpen: Bool) {
        let windows: [[String: Any]] = windowControllers.compactMap { controller in
            guard let window = controller.window, window.isVisible else { return nil }
            return ["tabs": controller.tabs.map(\.url.absoluteString), "selected": controller.selectedIndex,
                    "frame": NSStringFromRect(window.frame)]
        }
        AppDefaults.store.set(["windows": windows, "settings": settingsOpen] as [String: Any], forKey: Self.sessionKey)
    }

    /// Opens the windows saved by `restartKeepingWindows`; false when there are none.
    func restoreSession() -> Bool {
        guard let session = AppDefaults.store.dictionary(forKey: Self.sessionKey) else { return false }
        AppDefaults.store.removeObject(forKey: Self.sessionKey)
        for saved in session["windows"] as? [[String: Any]] ?? [] {
            let tabs = (saved["tabs"] as? [String] ?? []).compactMap(URL.init(string:)).map(ExplorerTab.init(url:))
            guard !tabs.isEmpty else { continue }
            let controller = openWindow(with: tabs)
            if let frame = (saved["frame"] as? String).map(NSRectFromString), frame.width > 0 {
                controller.window?.setFrame(frame, display: true)
                controller.keepOnScreen()
            }
            controller.selectTab(at: saved["selected"] as? Int ?? 0)
        }
        if session["settings"] as? Bool == true { showSettings(tab: .general) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The window in front is the one to come back next time
        isTerminating = true
        if let front = frontExplorerWindow { WindowPlacement.remember(front) }
        // Restarting into an update: the new version keeps the desktop, no Finder in between
        guard FinderReplacement.isApplied, !Updater.shared.isRelaunching else { return }
        desktop?.hide()
        FinderReplacement.restore()
    }

    /// Windows closing because the app quits don't count as "closed last".
    private(set) var isTerminating = false

    /// The frontmost visible folder window.
    private var frontExplorerWindow: NSWindow? {
        NSApp.orderedWindows.first { $0 is ExplorerWindow && $0.isVisible && !$0.isMiniaturized }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Dock

    /// Clicking the Dock icon: bring folder windows back, un-minimize one, or open a new window.
    /// (The desktop window always counts as "visible", so the system flag can't be used.)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let windows = windowControllers.compactMap(\.window)
        if windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) {
            windows.filter { $0.isVisible && !$0.isMiniaturized }.forEach { $0.orderFront(nil) }
            windows.first { $0.isVisible && !$0.isMiniaturized }?.makeKey()
        } else if let minimized = windows.first(where: \.isMiniaturized) {
            minimized.deminiaturize(nil)
        } else {
            openWindow(at: Settings.startURL)
        }
        return false
    }

    /// Right-click on the Dock icon: every open folder (tabs grouped by window) + "New window".
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for controller in windowControllers {
            guard let window = controller.window else { continue }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            for (index, tab) in controller.tabs.enumerated() {
                var title = tab.title
                if window.isMiniaturized && index == controller.selectedIndex { title += L(" (свёрнуто)") }
                let item = menu.addItem(withTitle: title, action: #selector(showFolderFromDock(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = DockTarget(controller: controller, tabID: tab.id)
                item.toolTip = tab.url.path
                // Checkmark on the tab each window is showing, like the system window list
                item.state = index == controller.selectedIndex && controller.tabs.count > 1 ? .on : .off
            }
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(withTitle: L("Новое окно"), action: #selector(newWindow(_:)), keyEquivalent: "").target = self
        return menu
    }

    private final class DockTarget: NSObject {
        weak var controller: ExplorerWindowController?
        let tabID: UUID
        init(controller: ExplorerWindowController, tabID: UUID) { self.controller = controller; self.tabID = tabID }
    }

    @objc private func showFolderFromDock(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? DockTarget, let controller = target.controller,
              let window = controller.window else { return }
        if let index = controller.tabs.firstIndex(where: { $0.id == target.tabID }) { controller.selectTab(at: index) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Opening folders from the outside

    func application(_ application: NSApplication, open urls: [URL]) {
        openedByEvent = true
        for url in urls {
            if url.isBrowsableDirectory { openWindow(at: url) } else { reveal(url) }
        }
    }

    @objc private func handleRevealEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        openedByEvent = true
        guard let direct = event.paramDescriptor(forKeyword: fourCC("----")) else { return }
        var urls: [URL] = []
        if direct.descriptorType == fourCC("list") {
            for i in stride(from: 1, through: direct.numberOfItems, by: 1) {
                if let url = direct.atIndex(i).flatMap(Self.fileURL) { urls.append(url) }
            }
        } else if let url = Self.fileURL(direct) {
            urls.append(url)
        }
        // One window per parent folder, with all revealed items selected
        for (parent, items) in Dictionary(grouping: urls, by: { $0.deletingLastPathComponent() }) {
            openWindow(at: parent, select: items)
        }
    }

    private static func fileURL(_ descriptor: NSAppleEventDescriptor) -> URL? {
        descriptor.coerce(toDescriptorType: fourCC("furl"))?.fileURLValue
    }

    // MARK: - Windows

    @discardableResult
    func openWindow(at url: URL, select: [URL] = []) -> ExplorerWindowController {
        let tab = ExplorerTab(url: url)
        tab.pendingSelection = select
        return openWindow(with: [tab])
    }

    @discardableResult
    func openWindow(with tabs: [ExplorerTab], origin: NSPoint? = nil) -> ExplorerWindowController {
        let controller = ExplorerWindowController(tabs: tabs)
        guard let window = controller.window else { return controller }
        if let origin {
            window.setFrameOrigin(origin)
        } else if let last = frontExplorerWindow ?? windowControllers.last?.window {
            window.setFrame(NSRect(origin: window.frame.origin, size: last.frame.size), display: false)
            window.setFrameTopLeftPoint(last.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else if let frame = WindowPlacement.restoredFrame() {
            // The first window comes back where the last used one was
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        windowControllers.append(controller)
        controller.keepOnScreen()
        NSApp.activate()
        controller.showWindow(nil)
        return controller
    }

    func windowControllerDidClose(_ controller: ExplorerWindowController) {
        windowControllers.removeAll { $0 === controller }
    }

    /// Folders open in a new WinEx window, everything else in its default app.
    func open(_ url: URL) {
        let url = FileCommands.resolved(url)
        if FileCommands.isZip(url) { return FileCommands.extract(url) }
        if url.isBrowsableDirectory { openWindow(at: url) } else { NSWorkspace.shared.open(url) }
    }

    func reveal(_ url: URL) {
        openWindow(at: url.deletingLastPathComponent(), select: [url])
    }

    /// Called when a window that was dragged by its tab is dropped. If it lands on another
    /// window's tab bar, its tabs are merged into that window (like Chrome).
    func windowDragEnded(_ window: NSWindow, at screenPoint: NSPoint) {
        guard let source = windowControllers.first(where: { $0.window === window }),
              let target = mergeTarget(for: window, at: screenPoint) else { return }
        let index = target.tabBar.insertionIndex(forScreenPoint: screenPoint)
        let tabs = source.tabs
        source.window?.close()
        target.insertTabs(tabs, at: index)
        target.window?.makeKeyAndOrderFront(nil)
    }

    /// The window whose tab strip `screenPoint` is over (the frontmost one), other than `window`.
    func mergeTarget(for window: NSWindow, at screenPoint: NSPoint) -> ExplorerWindowController? {
        NSApp.orderedWindows.lazy
            .filter { $0 !== window && $0.isVisible }
            .compactMap { w in self.windowControllers.first { $0.window === w } }
            .first { $0.tabBar.screenFrame.insetBy(dx: 0, dy: -8).contains(screenPoint) }
    }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "WinEx")

        let menu = NSMenu()
        menu.addItem(withTitle: L("Новое окно"), action: #selector(newWindow(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Рабочий стол"), action: #selector(openDesktopFolder(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Загрузки"), action: #selector(openDownloadsFolder(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Настройки…"), action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Мастер настройки…"), action: #selector(showSetupWizard(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Проверить обновления…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Выйти из WinEx (вернуть Finder)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.check(userInitiated: true)
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: Settings.startURL)
    }

    @objc private func openDesktopFolder(_ sender: Any?) {
        openWindow(at: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0])
    }

    @objc private func openDownloadsFolder(_ sender: Any?) {
        openWindow(at: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
    }

    @objc func showSetupWizard(_ sender: Any?) {
        SetupWizard.show()
    }

    @objc func showSettings(_ sender: Any?) {
        showSettings(tab: nil)
    }

    func showSettings(tab: SettingsWindowController.Tab?) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.sync()
        if let tab { settingsController?.select(tab) }
        NSApp.activate()
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        setShowHidden(!Settings.showHidden)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleHiddenFiles(_:)) {
            menuItem.state = Settings.showHidden ? .on : .off
        }
        return true
    }

    // MARK: - Settings

    func setReplaceFinder(_ on: Bool) {
        Settings.replaceFinder = on
        if on {
            enableFinderReplacement()
        } else {
            desktop?.hide()
            desktop = nil
            FinderReplacement.restore()
        }
    }

    /// Puts the WinEx desktop back the way Finder has it (icon places, size, sorting).
    func resetDesktopToFinder() {
        if let desktop { desktop.resetToFinder() } else { DesktopLayout.forget() }
    }

    func setShowHidden(_ on: Bool) {
        Settings.showHidden = on
        NotificationCenter.default.post(name: .showHiddenChanged, object: nil)
        settingsController?.sync()
    }

    private func enableFinderReplacement() {
        FinderReplacement.apply()
        if desktop == nil { desktop = DesktopController() }
        desktop?.show()
    }
}
