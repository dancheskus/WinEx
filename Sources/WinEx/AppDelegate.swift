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
        endRenamesOnWindowSwitch()
        closeTabsOfEjectedVolumes()
        SetupWizard.markExistingUser()
        setupStatusItem()
        DeviceImport.register()
        CloudProgress.shared.start()
        // Logging out / restarting / shutting down (sent before the apps are asked to quit)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionEnding = true }
            // Still here a minute later: the log out was cancelled (an app refused to quit)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.sessionEnding = false }
        }

        #if DEBUG
        Scenario.startIfRequested()
        #endif
        if Settings.replaceFinder { enableFinderReplacement() }
        #if DEBUG
        // Scenario runs must not take the shortcut from the user's WinEx
        if !Scenario.isRequested {
            GlobalHotKey.shared.apply()
            Updater.shared.startAutomaticChecks()
            DesktopSnapshots.startSchedule()
        }
        #else
        GlobalHotKey.shared.apply()
        Updater.shared.startAutomaticChecks()
        DesktopSnapshots.startSchedule()
        #endif
        // Tags already on files join the sidebar's list (one quick Spotlight query)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { TagLibrary.discover() }
        // Back from a restart (a new language, an update): the same windows as before
        var restored = restoreSession()
        // Just updated: what the new version brings (or that it didn't install). Updated by a
        // version that saved no windows for it: the ones it had open (written down as it ran)
        if Updater.shared.tellWhatsNewIfUpdated(), !restored {
            let windows = AppDefaults.store.array(forKey: Self.liveSessionKey) as? [[String: Any]] ?? []
            restoreWindows(windows)
            restored = !windows.isEmpty
        }
        #if DEBUG
        if !Scenario.isRequested { offerWindowsAfterCrash() }
        #else
        offerWindowsAfterCrash()
        #endif
        // The first launch (or back to the assistant after a restart it asked for)
        if SetupWizard.shouldShow { SetupWizard.show(); return }
        if restored { return }
        // Starting WinEx opens no window (the desktop and the menu bar icon come up); a click on
        // its Dock icon, the global shortcut or «Новое окно» opens one
        #if DEBUG
        if Scenario.isRequested { openWindow(at: Settings.startURL) }  // the scenarios work in a window
        #endif
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
        AppDefaults.store.set(["windows": openWindowsList(), "settings": settingsOpen] as [String: Any], forKey: Self.sessionKey)
    }

    /// The folder windows open now: their tabs, current tab and frames; minimized ones too (marked so).
    private func openWindowsList() -> [[String: Any]] {
        windowControllers.compactMap { controller in
            guard let window = controller.window, window.isVisible || window.isMiniaturized else { return nil }
            return ["tabs": controller.tabs.map(\.url.absoluteString), "selected": controller.selectedIndex,
                    "frame": NSStringFromRect(window.frame), "minimized": window.isMiniaturized]
        }
    }

    /// Opens the windows saved by `restartKeepingWindows`; false when there are none.
    func restoreSession() -> Bool {
        guard let session = AppDefaults.store.dictionary(forKey: Self.sessionKey) else { return false }
        AppDefaults.store.removeObject(forKey: Self.sessionKey)
        restoreWindows(session["windows"] as? [[String: Any]] ?? [])
        if session["settings"] as? Bool == true { showSettings(tab: .general) }
        return true
    }

    // MARK: - After a crash: offer the windows back

    /// While WinEx runs, the open windows are written down every few seconds; quitting normally
    /// clears the "running" mark. Started with the mark still there, WinEx didn't quit normally
    /// (it crashed or was force-quit): it offers to open those windows again.
    private static let liveSessionKey = "liveSession", runningKey = "running"
    private var lastWrittenWindows: NSArray?
    private var sessionTimer: Timer?

    #if DEBUG
    /// Scenario runs: the answer to «Восстановить окна?» (no dialog), and the check run as at launch.
    var debugCrashAnswer: Bool?
    func debugOfferWindowsAfterCrash() { offerWindowsAfterCrash() }
    #endif

    private func offerWindowsAfterCrash() {
        let store = AppDefaults.store
        let crashed = store.bool(forKey: Self.runningKey)
        let windows = store.array(forKey: Self.liveSessionKey) as? [[String: Any]] ?? []
        store.set(true, forKey: Self.runningKey)
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeLiveSession() }
        }
        guard crashed, !windows.isEmpty, windowControllers.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            #if DEBUG
            if let answer = self?.debugCrashAnswer {
                if answer { self?.restoreWindows(windows) }
                return
            }
            #endif
            let alert = NSAlert()
            alert.messageText = L("WinEx неожиданно завершил работу")
            let tabs = windows.reduce(0) { $0 + (($1["tabs"] as? [String])?.count ?? 0) }
            alert.informativeText = L("Открыть окна, которые были открыты (%@)?",
                                      "\(windows.count) \(plural(windows.count, L("окно"), L("окна"), L("окон"))), \(tabs) \(plural(tabs, L("вкладка"), L("вкладки"), L("вкладок")))")
            alert.addButton(withTitle: L("Восстановить окна"))
            alert.addButton(withTitle: L("Не нужно"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self?.restoreWindows(windows)
        }
    }

    /// Writes the open windows down when they've changed.
    private func writeLiveSession() {
        let windows = openWindowsList() as NSArray
        guard windows != lastWrittenWindows else { return }
        lastWrittenWindows = windows
        AppDefaults.store.set(windows, forKey: Self.liveSessionKey)
    }

    private func restoreWindows(_ list: [[String: Any]]) {
        for saved in list {
            let tabs = (saved["tabs"] as? [String] ?? []).compactMap(URL.init(string:)).map(ExplorerTab.init(url:))
            guard !tabs.isEmpty else { continue }
            let controller = openWindow(with: tabs)
            if let frame = (saved["frame"] as? String).map(NSRectFromString), frame.width > 0 {
                controller.window?.setFrame(frame, display: true)
                controller.keepOnScreen()
            }
            controller.selectTab(at: saved["selected"] as? Int ?? 0)
            // Minimized before: back in the Dock (its frame above is where it opens from there)
            if saved["minimized"] as? Bool == true { controller.window?.miniaturize(nil) }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        InlineRename.endAll()
    }

    /// A disk ejected (a disk image, a USB disk, a network share): its tabs close — a window showing
    /// only that disk closes, as Finder's does. A server left with no shares mounted: tabs showing
    /// it go to "Сеть" (Finder leaves the server's window too).
    private var unmountObserver: NSObjectProtocol?
    private var mountObserver: NSObjectProtocol?
    private func closeTabsOfEjectedVolumes() {
        Places.rememberShareServers()
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Places.rememberShareServers() }
        }
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                if let server = Places.server(ofEjected: volume), Places.mountedShares(on: server).isEmpty {
                    Places.disconnect(server)
                }
                let root = volume.standardizedFileURL.path
                func onVolume(_ tab: ExplorerTab) -> Bool {
                    guard let directory = Location(tab.url).directory?.standardizedFileURL.path else { return false }
                    return directory == root || directory.hasPrefix(root + "/")
                }
                for controller in self.windowControllers {
                    let gone = controller.tabs.indices.filter { onVolume(controller.tabs[$0]) }
                    guard !gone.isEmpty else { continue }
                    if gone.count == controller.tabs.count {
                        controller.mergedAway = true   // (not a «closed window» for ⇧⌘T: its disk is gone)
                        controller.window?.close()
                    } else {
                        for index in gone.reversed() { controller.closeTab(at: index) }
                    }
                }
            }
        }
    }

    /// A rename ends when its window stops being the key one (another WinEx window, the desktop).
    private var resignKeyObserver: NSObjectProtocol?
    private func endRenamesOnWindowSwitch() {
        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                // (Only while WinEx stays active: going to another app is handled above, the same way)
                guard NSApp.isActive, let window = note.object as? NSWindow else { return }
                InlineRename.end(in: window)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The window in front is the one to come back next time
        isTerminating = true
        // Quitting normally: no "WinEx quit unexpectedly" next time
        AppDefaults.store.set(false, forKey: Self.runningKey)
        if let front = frontExplorerWindow { WindowPlacement.remember(front) }
        // Restarting into an update: the new version keeps the desktop, no Finder in between
        guard FinderReplacement.isApplied, !Updater.shared.isRelaunching else { return }
        // The session ending (log out, restart, shut down) with WinEx opening at login: Finder's
        // desktop stays hidden, so WinEx's is the first one seen after the next login
        if sessionEnding, LoginItem.isEnabled {
            FinderReplacement.keepForNextLogin()
            return
        }
        desktop?.hide()
        FinderReplacement.restore()
    }

    /// Windows closing because the app quits don't count as "closed last".
    private(set) var isTerminating = false
    /// macOS is logging out, restarting or shutting down.
    private var sessionEnding = false

    /// The frontmost visible folder window.
    private var frontExplorerWindow: NSWindow? {
        NSApp.orderedWindows.first { $0 is ExplorerWindow && $0.isVisible && !$0.isMiniaturized }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Dock

    /// Clicking the Dock icon: bring folder windows back, un-minimize one, or open a new window.
    /// (The desktop window always counts as "visible", so the system flag can't be used.)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if SetupWizard.isActive {
            SetupWizard.show()
            return false
        }
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
        // A WinEx settings file double-clicked: offer to load it
        if let settings = urls.first(where: SettingsBackup.isSettingsFile) {
            DispatchQueue.main.async { SettingsBackup.open(settings) }
            let rest = urls.filter { !SettingsBackup.isSettingsFile($0) }
            guard !rest.isEmpty else { return }
            return self.application(application, open: rest)
        }
        // (Opened from another app: a folder already open is shown, not opened again)
        for url in urls where url.isBrowsableDirectory { showOrOpenWindow(at: url) }
        // Files: one window per folder, all of them selected (several from Finder's button at once)
        let files = urls.filter { !$0.isBrowsableDirectory }
        for (folder, items) in Dictionary(grouping: files, by: { $0.deletingLastPathComponent() }) {
            showOrOpenWindow(at: folder, select: items)
        }
    }

    /// A folder opened (from another app — Chrome's «Show downloads», the Dock, «Show in Finder» —
    /// or from the desktop, a portal, a zone): if a window already shows it (in any tab, even
    /// hidden or minimized), that window comes forward with that tab — the items selected;
    /// otherwise a new window. WinEx's own «new window» (⌘N, the hotkey) always opens one.
    func showOrOpenWindow(at folder: URL, select: [URL] = []) {
        func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let wanted = key(folder)
        // The frontmost window showing it first
        let ordered = NSApp.orderedWindows.compactMap { window in windowControllers.first { $0.window === window } }
        let candidates = ordered + windowControllers.filter { controller in !ordered.contains { $0 === controller } }
        for controller in candidates {
            guard let index = controller.tabs.firstIndex(where: { Location($0.url).directory.map(key) == wanted }) else { continue }
            controller.showTab(at: index, selecting: select)
            // Hidden (⌘H) or minimized: shown again
            if NSApp.isHidden { NSApp.unhide(nil) }
            if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openWindow(at: folder, select: select)
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
            showOrOpenWindow(at: parent, select: items)
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
        if url.isBrowsableDirectory { showOrOpenWindow(at: url) } else { NSWorkspace.shared.open(url) }
    }

    func reveal(_ url: URL) {
        showOrOpenWindow(at: url.deletingLastPathComponent(), select: [url])
    }

    /// Called when a window that was dragged by its tab is dropped. If it lands on another
    /// window's tab bar, its tabs are merged into that window (like Chrome).
    func windowDragEnded(_ window: NSWindow, at screenPoint: NSPoint) {
        guard let source = windowControllers.first(where: { $0.window === window }),
              let target = mergeTarget(for: window, at: screenPoint) else { return }
        let index = target.tabBar.insertionIndex(forScreenPoint: screenPoint)
        let tabs = source.tabs
        source.mergedAway = true   // (its tabs live on: not a closed window)
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
        if menuItem.action == #selector(reopenClosed(_:)) {
            // Says what it brings back: a tab or a whole window
            if case .window = closed.last { menuItem.title = L("Открыть закрытое окно") } else { menuItem.title = L("Открыть закрытую вкладку") }
            return !closed.isEmpty
        }
        return true
    }

    // MARK: - Reopening what was closed (⇧⌘T, like a browser)

    /// A closed tab (and the window it was in, if that's still open) or a closed window.
    private enum Closed {
        case tab(url: URL, in: WeakWindowController, at: Int)
        case window(tabs: [URL], selected: Int, frame: NSRect)
    }

    final class WeakWindowController {
        weak var controller: ExplorerWindowController?
        init(_ controller: ExplorerWindowController) { self.controller = controller }
    }

    /// Last closed last; a few dozen kept.
    private var closed: [Closed] = []

    func noteClosedTab(_ url: URL, in controller: ExplorerWindowController, at index: Int) {
        remember(.tab(url: url, in: WeakWindowController(controller), at: index))
    }

    func noteClosedWindow(_ controller: ExplorerWindowController) {
        guard let window = controller.window, !controller.tabs.isEmpty else { return }
        remember(.window(tabs: controller.tabs.map(\.url), selected: controller.selectedIndex, frame: window.frame))
    }

    private func remember(_ item: Closed) {
        closed.append(item)
        if closed.count > 30 { closed.removeFirst(closed.count - 30) }
    }

    /// ⇧⌘T: the tab or window closed last comes back — a tab into its window (where it was) if that
    /// window is still open, otherwise in a window of its own; a window with all its tabs, where it was.
    @objc func reopenClosed(_ sender: Any?) {
        guard let item = closed.popLast() else { return NSSound.beep() }
        switch item {
        case let .tab(url, holder, index):
            if let controller = holder.controller, let window = controller.window, window.isVisible {
                controller.insertTabs([ExplorerTab(url: url)], at: index)
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(at: url)
            }
        case let .window(tabs, selected, frame):
            let controller = openWindow(with: tabs.map(ExplorerTab.init(url:)))
            if frame.width > 0 {
                controller.window?.setFrame(frame, display: true)
                controller.keepOnScreen()
            }
            controller.selectTab(at: selected)
        }
    }

    // MARK: - Settings

    func setReplaceFinder(_ on: Bool) {
        Settings.replaceFinder = on
        defer { NotificationCenter.default.post(name: .replaceFinderChanged, object: nil) }
        if on {
            enableFinderReplacement()
        } else {
            desktop?.hide()
            desktop = nil
            FinderReplacement.restore()
        }
    }

    /// The desktop as a picture, for a snapshot (nil when WinEx doesn't draw the desktop).
    func desktopPreview() -> NSImage? { desktop?.previewImage() }

    /// A desktop snapshot was restored: the desktop takes the stored arrangement again.
    func reloadDesktopLayout() {
        desktop?.reloadLayout()
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
