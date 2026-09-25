#if DEBUG
import AppKit

/// Regression scenarios for `scripts/run-scenario.sh <name>`.
@MainActor
enum Scenarios {
    static let all: [String: (Scenario) -> Void] = [
        "undo": undo,
        "newfolder": newFolder,
        "slowclick": slowClick,
        "perf": perf,
        "hittest": hitTest,
        "desktop": desktop,
        "placement": placement,
        "desktopreset": desktopReset,
        "placement2": placementSecondScreen,
        "mousedrag": mouseDrag,
        "monitorgone": monitorGone,
        "fileops": fileOps,
        "search": search,
        "filecommands": fileCommands,
        "drives": drives,
        "trashaccess": trashAccess,
        "update": update,
        "settings": settingsTabs,
        "sidebar": sidebar,
        "commandbar": commandBarScenario,
        "menuswitch": menuSwitch,
        "look": look,
        "addressclick": addressClick,
        "breadcrumbs": breadcrumbs,
        "contextmenu": contextMenu,
        "unzip": unzip,
        "paste": pasteKeys,
        "selfupdate": selfUpdate,
        "updated": updated,
    ]

    /// A real-timed click (button held 0.15 s) beside the breadcrumbs switches to typing with the
    /// whole path selected — five times in a row; Esc brings the breadcrumbs back each time.
    static func addressClick(_ s: Scenario) {
        let base = s.makeFiles(["a.txt"])
        s.window?.navigate(to: base)
        func bar() -> BreadcrumbBar? { s.find(BreadcrumbBar.self, in: s.window?.window?.contentView) }
        func selection() -> String {
            guard let editor = s.window?.window?.firstResponder as? NSTextView else { return "not editing" }
            let range = editor.selectedRange, length = (editor.string as NSString).length
            return range.length == length && length > 0 ? "all" : "\(range.length) of \(length)"
        }
        var results: [String] = []
        func round(_ n: Int) {
            guard n < 5 else {
                s.note("  5 clicks: \(results)  expect all")
                s.run([])
                return
            }
            guard let bar = bar(), let window = bar.window else { s.note("  (no breadcrumbs)"); s.run([]); return }
            window.makeFirstResponder(s.table)
            let point = bar.convert(NSPoint(x: bar.bounds.maxX - 12, y: bar.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let release = Timer(timeInterval: 0.15, repeats: false) { _ in
                if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            }
            RunLoop.main.add(release, forMode: .common)
            if let down = event(.leftMouseDown) { NSApp.sendEvent(down) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                results.append(selection())
                s.key("\u{1b}", code: 53)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { round(n + 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { round(0) }
    }

    /// The breadcrumb bar: steps for a few places, a click on a step, a click beside them (typing),
    /// Esc back; photographed wide (scripts/capture-window.sh breadcrumbs).
    static func breadcrumbs(_ s: Scenario) {
        let deep = s.makeFiles(["x.txt"], in: "Проекты/2026/Отчёты")
        let fm = FileManager.default
        for place in [fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"), Places.trashURL, Places.computerURL] {
            let crumbs = BreadcrumbBar.path(for: Location(place)).crumbs.map(\.title)
            s.note("  \(place.lastPathComponent): \(crumbs.joined(separator: " › "))")
        }
        s.window?.navigate(to: deep)
        s.window?.window?.setFrame(NSRect(x: 150, y: 200, width: 1400, height: 600), display: true)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        func bar() -> BreadcrumbBar? { s.find(BreadcrumbBar.self, in: s.window?.window?.contentView) }
        func buttons() -> [CrumbButton] { bar().map { s.findAll(CrumbButton.self, in: $0) } ?? [] }
        s.run([
            (1.0, "photograph", {
                s.note("  steps: \(buttons().compactMap(\.toolTip).suffix(4))")
                if let window = s.window?.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
            }),
            (2.0, "click the step «Проекты»", {
                guard let step = buttons().first(where: { $0.toolTip?.hasSuffix("/Проекты") == true }), let event = NSApp.currentEvent else { s.note("  (no step)"); return }
                step.mouseDown(with: event)
            }),
            (0.6, "where", { s.note("  now in: \(s.window?.selectedTab.title ?? "?")  expect Проекты") }),
            (0.2, "click beside the steps", {
                guard let bar = bar(), let window = bar.window,
                      let event = NSEvent.mouseEvent(with: .leftMouseDown, location: bar.convert(NSPoint(x: bar.bounds.maxX - 10, y: bar.bounds.midY), to: nil),
                                                     modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                bar.mouseDown(with: event)
            }),
            (0.4, "typing?", {
                let editor = s.window?.window?.firstResponder as? NSTextView
                let all = editor.map { $0.selectedRange.length == ($0.string as NSString).length } ?? false
                s.note("  typing: \(editor != nil), all selected: \(all), breadcrumbs hidden: \(bar()?.isHidden == true)  expect true, true, true")
                s.key("\u{1b}", code: 53)
            }),
            (0.4, "after Esc", { s.note("  breadcrumbs back: \(bar()?.isHidden == false)  expect true") }),
        ])
    }

    /// Sidebar drops without the mouse (a stand-in NSDraggingInfo goes to the data source):
    /// folders pinned between the favourites, favourites reordered, files dropped on a folder,
    /// on a tag, on the Trash bar; then the sidebar and the Trash are photographed.
    static func sidebar(_ s: Scenario) {
        let base = s.makeFiles(["в папку.txt", "с тегом.txt"])
        let fm = FileManager.default
        for name in ["Альфа", "Бета", "Цель"] { try? fm.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true) }
        let (alpha, beta, target) = (base.appendingPathComponent("Альфа"), base.appendingPathComponent("Бета"), base.appendingPathComponent("Цель"))
        s.window?.navigate(to: base)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        func outline() -> NSOutlineView? {
            s.findAll(NSOutlineView.self, in: s.window?.window?.contentView ?? NSView()).first { $0.dataSource is SidebarViewController }
        }
        func sidebar() -> SidebarViewController? { outline()?.dataSource as? SidebarViewController }
        func section(_ kind: SidebarViewController.Section.Kind) -> SidebarViewController.Section? {
            guard let outline = outline() else { return nil }
            return (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? SidebarViewController.Section }.first { $0.kind == kind }
        }
        func favorites() -> [String] { section(.favorites)?.items.map(\.title) ?? [] }
        func drop(_ info: FakeDrag, on item: Any?, index: Int) -> String {
            guard let outline = outline(), let sidebar = sidebar() else { return "no sidebar" }
            let operation = sidebar.outlineView(outline, validateDrop: info, proposedItem: item, proposedChildIndex: index)
            guard operation != [] else { return "refused" }
            return sidebar.outlineView(outline, acceptDrop: info, item: item, childIndex: index) ? "op \(operation.rawValue)" : "failed"
        }
        s.run([
            (1.0, "pin Альфа", {
                SidebarConfig.pin(alpha)
                s.note("  favourites end with: \(favorites().suffix(2))  expect […, Альфа]")
            }),
            (0.3, "drop Бета between the first two favourites", {
                let result = drop(FakeDrag(urls: [beta]), on: section(.favorites), index: 1)
                s.note("  \(result); favourites start: \(favorites().prefix(3))  expect Бета second")
            }),
            (0.3, "drop a file between favourites (only folders pin)", {
                s.note("  \(drop(FakeDrag(urls: [base.appendingPathComponent("в папку.txt")]), on: section(.favorites), index: 0))  expect refused")
            }),
            (0.3, "drag favourite Альфа to the top", {
                let result = drop(FakeDrag(favorite: alpha.path), on: section(.favorites), index: 0)
                s.note("  \(result); favourites start: \(favorites().prefix(3))  expect Альфа first")
            }),
            (0.3, "pin Цель, drop a file on it", {
                SidebarConfig.pin(target)
                let item = section(.favorites)?.items.first { $0.title == "Цель" }
                s.note("  \(drop(FakeDrag(urls: [base.appendingPathComponent("в папку.txt")]), on: item, index: -1))")
            }),
            (1.5, "moved?", { s.note("  in Цель: \(s.files(in: target))  expect [в папку.txt]") }),
            (0.2, "drop a file on the tag «Красный»", {
                let item = section(.tags)?.items.first { $0.title == "Красный" }
                let file = base.appendingPathComponent("с тегом.txt")
                s.note("  \(drop(FakeDrag(urls: [file]), on: item, index: -1)); tags: \(FileTags.tags(of: file).map(\.name))  expect [Красный]")
            }),
            (0.3, "remove Бета from the sidebar", {
                SidebarConfig.unpin(beta)
                s.note("  favourites: \(favorites())")
            }),
            (0.5, "photograph the sidebar", {
                if let window = s.window?.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
            }),
            (1.5, "the Trash", { s.window?.navigate(to: Places.trashURL) }),
            (1.0, "photograph the Trash", {
                if let window = s.window?.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-1"), atomically: true, encoding: .utf8)
                }
            }),
            (1.5, "unpin the sandbox folders", { [alpha, target].forEach(SidebarConfig.unpin) }),
        ])
    }

    /// The command bar, its menus, the column header menu and the address bar menu, each
    /// photographed by scripts/capture-window.sh commandbar 7.
    static func commandBarScenario(_ s: Scenario) {
        let base = s.makeFiles(["отчёт.docx", "заметки.txt", "фото.png"])
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        s.window?.window?.setFrame(NSRect(x: 150, y: 200, width: 1200, height: 560), display: true)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        let content = s.window?.window?.contentView
        func bar() -> CommandBar? { s.find(CommandBar.self, in: content) }
        /// Hands a window to the script and goes on once it has been photographed.
        @MainActor func shot(_ index: Int, window number: Int?, then next: @escaping @MainActor () -> Void) {
            if let number { try? "\(number)".write(to: s.output.appendingPathComponent("tab-\(index)"), atomically: true, encoding: .utf8) }
            @MainActor func wait(_ tries: Int) {
                if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-\(index)").path) || tries == 0 || number == nil { return next() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { wait(tries - 1) }
            }
            wait(50)
        }
        /// Opens a menu (the call blocks while it tracks), photographs it, closes it with Esc.
        @MainActor func menuShot(_ index: Int, open: () -> Void, then next: @escaping @MainActor () -> Void) {
            let find = Timer(timeInterval: 0.6, repeats: false) { _ in
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let menus = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) == 101 }
                if let number = menus.first?[kCGWindowNumber as String] as? Int {
                    try? "\(number)".write(to: s.output.appendingPathComponent("tab-\(index)"), atomically: true, encoding: .utf8)
                } else {
                    s.note("  (no menu window)")
                }
                let close = Timer(timeInterval: 0.2, repeats: true) { timer in
                    guard FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-\(index)").path) || menus.isEmpty else { return }
                    timer.invalidate()
                    if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(esc, atStart: false)
                    }
                }
                RunLoop.main.add(close, forMode: .common)
            }
            RunLoop.main.add(find, forMode: .common)
            // The sort menu: highlight "Дополнительно" (↓ × 4) and open it (→), for the arrow
            if index == 1 {
                let keys = Timer(timeInterval: 0.25, repeats: false) { _ in
                    for (key, code) in [(NSDownArrowFunctionKey, 125), (NSDownArrowFunctionKey, 125), (NSDownArrowFunctionKey, 125),
                                        (NSDownArrowFunctionKey, 125), (NSRightArrowFunctionKey, 124)] {
                        guard let scalar = UnicodeScalar(key) else { continue }
                        let text = String(Character(scalar))
                        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                                        isARepeat: false, keyCode: UInt16(code)) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
                RunLoop.main.add(keys, forMode: .common)
            }
            open()
            DispatchQueue.main.async { next() }
        }
        func rightClick(_ view: NSView, at point: NSPoint) -> NSEvent? {
            guard let window = view.window else { return nil }
            return NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            s.select("заметки.txt")
            s.note("  bar: \(bar() != nil), cut enabled: \(bar()?.cutButton.isEnabled == true), new enabled: \(bar()?.newButton.isEnabled == true)  expect true, true, true")
            shot(0, window: s.window?.window?.windowNumber) {
                menuShot(1, open: { bar()?.sortButton.onClick?() }) {
                    menuShot(2, open: { bar()?.viewButton.onClick?() }) {
                        menuShot(3, open: { bar()?.moreButton.onClick?() }) {
                            guard let table = s.table, let header = table.headerView,
                                  let typeColumn = Optional(table.column(withIdentifier: .init("type"))), typeColumn >= 0,
                                  let event = rightClick(header, at: NSPoint(x: header.headerRect(ofColumn: typeColumn).midX, y: header.bounds.midY)) else {
                                s.note("  (no header)"); s.run([]); return
                            }
                            menuShot(4, open: {
                                if let menu = header.menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: header) }
                            }) {
                                guard let crumbs = s.find(BreadcrumbBar.self, in: content),
                                      let event = rightClick(crumbs, at: NSPoint(x: crumbs.bounds.maxX - 30, y: crumbs.bounds.midY)) else {
                                    s.note("  (no address bar)"); s.run([]); return
                                }
                                menuShot(5, open: {
                                    if let menu = crumbs.menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: crumbs) }
                                }) {
                                    // Show "Дата создания", fit every column
                                    guard let table = s.table else { s.run([]); return }
                                    table.tableColumn(withIdentifier: .init("created"))?.isHidden = false
                                    let before = table.tableColumns.filter { !$0.isHidden }.map { "\($0.identifier.rawValue) \(Int($0.width))" }
                                    s.note("  columns: \(before)")
                                    shot(6, window: s.window?.window?.windowNumber) { s.run([]) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// With "Просмотреть" open, a click on "Сортировать" should open the sort menu (Explorer),
    /// and nothing should reopen "Просмотреть" afterwards. Clicks are posted events.
    static func menuSwitch(_ s: Scenario) {
        let base = s.makeFiles(["a.txt"])
        s.window?.navigate(to: base)
        s.window?.window?.setFrame(NSRect(x: 150, y: 200, width: 1200, height: 560), display: true)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        var opened: [String] = []
        func bar() -> CommandBar? { s.find(CommandBar.self, in: s.window?.window?.contentView) }
        func click(_ button: NSView) {
            guard let window = button.window else { return }
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let bar = bar() else { s.note("  (no bar)"); s.run([]); return }
            bar.onMenuOpen = { opened.append($0) }
            click(bar.viewButton)
            // While "Просмотреть" tracks: click "Сортировать"
            let second = Timer(timeInterval: 0.8, repeats: false) { _ in click(bar.sortButton) }
            RunLoop.main.add(second, forMode: .common)
            // Close whatever is open after that
            let closer = Timer(timeInterval: 0.4, repeats: true) { timer in
                guard opened.count >= 2 else { return }
                timer.invalidate()
                if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                              isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(esc, atStart: false)
                }
            }
            RunLoop.main.add(closer, forMode: .common)
            s.run([
                (3.5, "menus opened", { s.note("  \(opened)  expect [view, sort]") }),
                (0.2, "click Сортировать once more", { opened = []; click(bar.sortButton) }),
                (1.0, "which opened", {
                    s.note("  \(opened)  expect [sort]")
                    if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(esc, atStart: false)
                    }
                }),
            ])
        }
    }

    /// A drag that isn't one: its pasteboard carries files or a sidebar favourite.
    final class FakeDrag: NSObject, NSDraggingInfo {
        let draggingPasteboard = NSPasteboard.withUniqueName()
        @MainActor init(urls: [URL] = [], favorite: String? = nil) {
            super.init()
            if let favorite {
                let item = NSPasteboardItem()
                item.setString(favorite, forType: .init("dev.winex.sidebar-favorite"))
                draggingPasteboard.writeObjects([item])
            } else {
                draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
            }
        }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .link, .generic] }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// Opens a file's context menu and hands its window to scripts/capture-window.sh contextmenu.
    static func contextMenu(_ s: Scenario) {
        let base = s.makeFiles(["отчёт.docx", "заметки.txt"])
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let table = s.table, let menu = table.menu, let window = table.window else { s.note("  (no table)"); s.run([]); return }
            s.select("отчёт.docx")
            let row = table.selectedRow
            let point = table.convert(NSPoint(x: 80, y: table.rect(ofRow: max(row, 0)).midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            // While the menu tracks, timers in the common modes still fire: find the menu's window,
            // let the script photograph it, then close the menu
            let find = Timer(timeInterval: 0.6, repeats: false) { _ in
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                // The context menu itself: menu level, the tallest (a submenu may be open beside it)
                let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) == 101 }
                func height(_ info: [String: Any]) -> CGFloat {
                    (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.height ?? 0
                }
                if let number = mine.max(by: { height($0) < height($1) })?[kCGWindowNumber as String] as? Int {
                    try? "\(number)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
                s.note("  menu items: \(menu.items.filter { !$0.isSeparatorItem }.map { $0.view != nil ? "[row]" : $0.title + ($0.image == nil ? "" : "🖼") }.prefix(9))")
                let close = Timer(timeInterval: 0.2, repeats: true) { timer in
                    if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-0").path) {
                        timer.invalidate()
                        menu.cancelTracking()
                    }
                }
                RunLoop.main.add(close, forMode: .common)
            }
            RunLoop.main.add(find, forMode: .common)
            // WINEX_MENU_TEST=N: highlight the N-th item with the keyboard (↓ × N) for the picture
            if let downs = Int(ProcessInfo.processInfo.environment["WINEX_MENU_TEST"] ?? ""), downs > 0 {
                let highlight = Timer(timeInterval: 0.3, repeats: false) { _ in
                    let arrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
                    for _ in 0..<downs {
                        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: 0, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                                                       isARepeat: false, keyCode: 125) {
                            NSApp.postEvent(down, atStart: false)
                        }
                    }
                }
                RunLoop.main.add(highlight, forMode: .common)
            }
            // A real right-click on the row (the table records it as the clicked row)
            table.rightMouseDown(with: event)
            s.run([])
        }
    }

    /// A big archive: the extraction window with its percentage (scripts/capture-window.sh unzip).
    static func unzip(_ s: Scenario) {
        let source = s.makeFiles([], in: "big")
        let chunk = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for i in 1...1500 { FileManager.default.createFile(atPath: source.appendingPathComponent("file-\(i).bin").path, contents: chunk) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", source.path, s.sandbox.appendingPathComponent("big.zip").path]
        try? zip.run()
        zip.waitUntilExit()
        try? FileManager.default.removeItem(at: source)
        s.note("  archive: \(s.files())")
        FileCommands.extract(s.sandbox.appendingPathComponent("big.zip"))
        func wait(_ tries: Int) {
            if let window = NSApp.windows.first(where: { $0.isVisible && ($0.title.contains("%") || $0.title.contains("Подготовка")) }) {
                s.note("  window: \(window.title)")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { s.run([]) }   // lets the extraction finish
                return
            }
            guard tries > 0 else { s.note("  (no progress window — too fast?)"); s.run([]); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { wait(tries - 1) } }
        }
        wait(60)
    }

    /// ⌘C then ⌘V as real key presses (through the window, like the keyboard), in the table and
    /// in the icon view, before and after a context menu was built.
    static func pasteKeys(_ s: Scenario) {
        let base = s.makeFiles(["a.txt"])
        s.window?.navigate(to: base)
        func press(_ key: String, _ code: UInt16) { s.key(key, code: code, modifiers: .command) }
        s.run([
            (0.6, "table: ⌘C ⌘V", { s.setViewMode(.details); s.select("a.txt"); press("c", 8); press("v", 9) }),
            (1.0, "result", { s.note("  \(s.files())  expect a - копия.txt") }),
            (0.2, "open and close the context menu, then ⌘V", {
                if let table = s.table, let menu = table.menu { menu.delegate?.menuNeedsUpdate?(menu) }
                s.select("a.txt"); press("c", 8); press("v", 9)
            }),
            (1.0, "result", { s.note("  \(s.files())  expect a - копия (2).txt") }),
            (0.2, "icons: ⌘C ⌘V", {
                s.setViewMode(.mediumIcons)
                s.select("a.txt")
                let responder = s.window?.window?.firstResponder
                let pasteTarget = NSApp.target(forAction: #selector(NSText.paste(_:)))
                s.note("  first responder: \(responder.map { "\(type(of: $0))" } ?? "-"), paste goes to: \(pasteTarget.map { "\(type(of: $0))" } ?? "-"), selected: \(s.selectedNames)")
                press("c", 8)
                s.note("  clipboard after ⌘C: \(NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])")
                press("v", 9)
            }),
            (1.0, "result", { s.note("  \(s.files())  expect a third copy") }),
            (0.2, "icons: ⌘V through the main menu directly", {
                s.select("a.txt")
                s.key("v", code: 9, modifiers: .command, viaMenu: true)
            }),
            (1.0, "result", { s.note("  \(s.files())  (main menu path)") }),
            (0.2, "focus in the sidebar (after a click there), then ⌘V", {
                if let outline = s.find(NSOutlineView.self, in: s.window?.window?.contentView) { s.window?.window?.makeFirstResponder(outline) }
                s.note("  paste goes to: \(NSApp.target(forAction: #selector(NSText.paste(_:))).map { "\(type(of: $0))" } ?? "nobody")")
                press("v", 9)
            }),
            (1.0, "result", { s.note("  \(s.files())  expect one more copy") }),
            (0.2, "who swallows ⌘V in the window?", {
                guard let window = s.window?.window,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) else { return }
                @MainActor func walk(_ view: NSView, _ depth: Int) {
                    for sub in view.subviews where !sub.isHiddenOrHasHiddenAncestor {
                        if sub.performKeyEquivalent(with: event) { s.note("  handled by \(type(of: sub)) (depth \(depth))"); return }
                        walk(sub, depth + 1)
                    }
                }
                if let content = window.contentView { walk(content, 0) }
            }),
            (1.0, "result", { s.note("  \(s.files())") }),
        ])
    }

    /// A window to photograph (scripts/capture-window.sh look): two tabs, some files, the icon view.
    static func look(_ s: Scenario) {
        let base = s.makeFiles(["Документы/", "Проекты/", "отчёт.pdf", "заметки.txt", "фото.png", "таблица.xlsx", "xiaomi vacuum 5 pro token.rtf"])
        s.window?.navigate(to: base)
        s.window?.addTab(url: FileManager.default.homeDirectoryForCurrentUser, select: false)
        s.window?.window?.setFrame(NSRect(x: 200, y: 200, width: 1000, height: 620), display: true)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = s.window?.window else { s.run([]); return }
            s.note("  view: \(ViewMode.saved.title)")
            let sidebar = s.find(NSOutlineView.self, in: window.contentView)?.enclosingScrollView?.superview
            s.note("  sidebar width: \(Int(sidebar?.frame.width ?? -1))  expect 200")
            // Finder-style selection: a folder and a long name
            if let grid = s.grid {
                let names = (0..<grid.count).map { (grid.item(at: IndexPath(item: $0, section: 0)) as? FileGridItem)?.textField?.stringValue ?? "" }
                let picked = IndexSet(names.indices.filter { names[$0] == "Проекты" || names[$0].hasPrefix("xiaomi") })
                grid.setSelection(picked, anchor: picked.first ?? 0)
                window.makeFirstResponder(grid)
                if ProcessInfo.processInfo.environment["WINEX_MENU_TEST"] == "rename" {
                    let one = IndexSet(names.indices.filter { names[$0] == "таблица.xlsx" })
                    grid.setSelection(one, anchor: one.first ?? 0)
                    s.send("renameSelected:")
                }
            }
            try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
            @MainActor func wait(_ tries: Int) {
                if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-0").path) || tries == 0 { s.run([]); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { wait(tries - 1) } }
            }
            wait(50)
        }
    }

    /// Run by scripts/check-self-update.sh on a copy of the app: updates itself from a local feed.
    static func selfUpdate(_ s: Scenario) {
        s.note("  running \(Updater.shared.currentVersion) from \(Bundle.main.bundlePath)")
        Updater.shared.check(userInitiated: true)
        // The update quits this process; if it doesn't within 20 s, say so
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { s.note("  (still running — no update happened)"); s.run([]) }
    }

    /// The relaunched copy after "selfupdate": reports its version and quits.
    static func updated(_ s: Scenario) {
        s.note("  after the update: \(Updater.shared.currentVersion) from \(Bundle.main.bundlePath)")
        s.run([])
    }

    /// Opens Settings and shows each tab in turn, waiting for an outside `screencapture -l` of the
    /// window (writes <out>/tab-N with the window number, waits for <out>/shot-N).
    static func settingsTabs(_ s: Scenario) {
        AppDelegate.shared.showSettings(nil)
        func tabs() -> NSTabViewController? { NSApp.windows.first { $0.title.hasPrefix("Настройки") || $0.contentViewController is NSTabViewController }?.contentViewController as? NSTabViewController }
        @MainActor func step(_ index: Int) {
            guard let tabs = tabs(), let window = tabs.view.window else { s.note("  (no settings window)"); s.run([]); return }
            guard index < tabs.tabViewItems.count else { window.close(); s.run([]); return }
            tabs.selectedTabViewItemIndex = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                s.note("  \(tabs.tabViewItems[index].label): \(Int(window.frame.width))×\(Int(window.frame.height))")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-\(index)"), atomically: true, encoding: .utf8)
                @MainActor func wait(_ tries: Int) {
                    if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-\(index)").path) || tries == 0 { step(index + 1); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { wait(tries - 1) }
                }
                wait(50)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step(0) }
    }

    /// The updater's download and signature check (without the restart): a build signed with our
    /// certificate is accepted, an ad-hoc copy is refused. Uses this very app as the "release".
    static func update(_ s: Scenario) {
        let fm = FileManager.default
        let good = s.sandbox.appendingPathComponent("WinEx.app")
        let forged = s.sandbox.appendingPathComponent("forged/WinEx.app")
        try? fm.createDirectory(at: forged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: Bundle.main.bundleURL, to: good)
        try? fm.copyItem(at: Bundle.main.bundleURL, to: forged)
        func shell(_ command: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            try? process.run()
            process.waitUntilExit()
        }
        shell("codesign --force --sign - '\(forged.path)' 2>/dev/null")
        shell("cd '\(s.sandbox.path)' && ditto -c -k --keepParent WinEx.app good.zip && cd forged && ditto -c -k --keepParent WinEx.app ../forged.zip")
        s.note("  running app signed with a certificate: \(Updater.isSignedLikeUs(Bundle.main.bundleURL))")
        Task { @MainActor in
            // The latest real release from GitHub, as the updater would get it
            if let url = URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest"),
               let data = try? await URLSession.shared.data(from: url).0,
               let release = try? JSONDecoder().decode(Updater.Release.self, from: data), let asset = release.archive,
               let app = try? await Updater.shared.download(asset.browser_download_url) {
                s.note("  GitHub \(release.tag_name): \(asset.name) → accepted: \(Updater.isSignedLikeUs(app))  expect true")
            } else {
                s.note("  (no release on GitHub)")
            }
            for name in ["good", "forged"] {
                do {
                    let app = try await Updater.shared.download(s.sandbox.appendingPathComponent("\(name).zip"))
                    s.note("  \(name).zip → \(app.lastPathComponent), accepted: \(Updater.isSignedLikeUs(app))  expect \(name == "good")")
                } catch {
                    s.note("  \(name).zip: \(error.localizedDescription)")
                }
            }
            s.run([])
        }
    }

    /// Can this build read the Trash (Full Disk Access)? Launch with `open` so that macOS checks
    /// WinEx itself, not the terminal that started it.
    static func trashAccess(_ s: Scenario) {
        s.run([
            (0.2, "read ~/.Trash", {
                do {
                    let items = try FileManager.default.contentsOfDirectory(atPath: Places.trashURL.path)
                    s.note("  ok: \(items.count) items")
                } catch {
                    s.note("  error: \(error.localizedDescription)")
                }
                // Granted once with the persistent signature: this build must read it without asking
                let desktop = (try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path))?.count
                s.note("  Desktop: \(desktop.map { "ok, \($0) items" } ?? "no access")")
            }),
        ])
    }

    /// "Этот Mac", empty-folder and Trash messages, the size of the selection, the start folder.
    static func drives(_ s: Scenario) {
        let base = s.makeFiles(["dir/", "empty/"])
        FileManager.default.createFile(atPath: base.appendingPathComponent("big.bin").path, contents: Data(count: 3_000_000))
        FileManager.default.createFile(atPath: base.appendingPathComponent("dir/inner.bin").path, contents: Data(count: 1_000_000))
        func status() -> String {
            s.window?.statusText ?? "?"
        }
        func message() -> String {
            guard let view = (s.window?.window?.contentView).flatMap({ s.find(EmptyStateView.self, in: $0) }), !view.isHidden else { return "-" }
            return s.findAll(NSTextField.self, in: view).map(\.stringValue).filter { !$0.isEmpty }.joined(separator: " | ")
        }
        s.run([
            (0.8, "Этот Mac", { s.window?.navigate(to: Places.computerURL) }),
            (1.5, "drives", {
                s.note("  \(s.window?.selectedTab.title ?? "?"): \(status())")
                guard let drives = (s.window?.window?.contentView).flatMap({ s.find(DrivesView.self, in: $0) }) else { return }
                let data = drives.dataWithPDF(inside: drives.bounds)
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: s.output.appendingPathComponent("drives.png"))
                }
            }),
            (0.2, "an empty folder", { s.window?.navigate(to: base.appendingPathComponent("empty")) }),
            (0.8, "message", { s.note("  \(message())  expect Эта папка пуста") }),
            (0.2, "the Trash", { s.window?.navigate(to: Places.trashURL) }),
            (0.8, "message", { s.note("  \(message())") }),
            (0.2, "select big.bin and dir", {
                s.window?.navigate(to: base)
                s.setViewMode(.details)
            }),
            (0.8, "selection", {
                guard let table = s.table else { return }
                let rows = (0..<table.numberOfRows).filter { ["big.bin", "dir"].contains((table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? "") }
                table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
                s.note("  right away: \(status())")
            }),
            (1.0, "counted", { s.note("  later: \(status())  expect 4 MB") }),
            (0.2, "start folder: Рабочий стол", {
                Settings.startFolder = "desktop"
                AppDelegate.shared.newWindow(nil)
                s.note("  new window: \(AppDelegate.shared.windowControllers.last?.selectedTab.title ?? "?")  expect Рабочий стол / Desktop")
                Settings.startFolder = "home"
            }),
            (0.3, "the start folder menu in Settings", {
                AppDelegate.shared.showSettings(nil)
                let window = NSApp.windows.first { $0.title == "Настройки WinEx" }
                let popups = (window?.contentView).map { s.findAll(NSPopUpButton.self, in: $0) } ?? []
                let start = popups.first { $0.itemTitles.contains("Рабочий стол") }
                s.note("  items: \(start?.itemTitles ?? [])  selected: \(start?.titleOfSelectedItem ?? "-")")
                window?.close()
            }),
        ])
    }

    /// Duplicate, compress, extract (double-click), alias (open, show original), package contents,
    /// Windows keys, the global shortcut's registration.
    static func fileCommands(_ s: Scenario) {
        let base = s.makeFiles(["a.txt", "dir/", "Pkg.app/", "Pkg.app/Contents/"])
        s.makeFiles(["inner.txt"], in: "dir")
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        func open(_ name: String) {
            s.select(name)
            s.send("openSelected:")
        }
        s.run([
            (0.8, "duplicate a.txt", { s.select("a.txt"); s.send("duplicate:") }),
            (0.8, "compress a.txt, then a.txt + dir", {
                s.note("  \(s.files())  expect a - копия.txt")
                s.select("a.txt"); s.send("compress:")
            }),
            (1.0, "compress two", {
                s.table?.selectRowIndexes(IndexSet((0..<(s.table?.numberOfRows ?? 0)).filter { row in
                    ["a.txt", "dir"].contains((s.table?.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? "")
                }), byExtendingSelection: false)
                s.send("compress:")
            }),
            (1.5, "double-click Архив.zip", {
                s.note("  \(s.files())  expect a.txt.zip, Архив.zip")
                // A file compressed alone holds just the file, not its parent folder
                let list = Process()
                list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
                list.arguments = ["-1", base.appendingPathComponent("a.txt.zip").path]
                let pipe = Pipe()
                list.standardOutput = pipe
                try? list.run()
                list.waitUntilExit()
                let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n").filter { !$0.hasPrefix("__MACOSX") }
                s.note("  a.txt.zip holds: \(entries)  expect [a.txt]")
                open("Архив.zip")
            }),
            (1.5, "extracted", {
                s.note("  \(s.files())  expect folder Архив")
                s.note("  Архив: \(s.files(in: base.appendingPathComponent("Архив")))  expect a.txt, dir")
            }),
            (0.2, "alias of dir", { s.select("dir"); s.send("makeAlias:") }),
            (0.8, "open the alias", {
                let alias = base.appendingPathComponent("dir псевдоним")
                s.note("  alias: \(FileCommands.isAlias(alias)), points to: \(FileCommands.original(of: alias)?.lastPathComponent ?? "-")")
                open("dir псевдоним")
            }),
            (0.8, "where are we", {
                s.note("  \(s.window?.selectedTab.title ?? "?")  expect dir")
                s.window?.goBack(nil)
            }),
            (0.8, "show package contents", { s.select("Pkg.app"); s.send("showPackageContents:") }),
            (0.8, "inside the package", {
                s.note("  \(s.window?.selectedTab.title ?? "?") → \(s.names())  expect Pkg, [Contents]")
            }),
            (0.2, "Windows keys: ⌥← back, ⌃Tab with two tabs", {
                Settings.windowsKeys = true
                s.window?.window?.makeFirstResponder(s.table)
                s.key("", code: 123, modifiers: .option)
            }),
            (0.6, "after ⌥←", {
                s.note("  \(s.window?.selectedTab.title ?? "?")  expect the sandbox folder")
                s.window?.newTab(nil)
            }),
            (0.5, "⌃1", {
                s.key("1", code: 18, modifiers: .control)
                s.note("  tab \((s.window?.selectedIndex ?? -1) + 1) of \(s.window?.tabs.count ?? 0)  expect 1 of 2")
                s.key("\t", code: 48, modifiers: .control)
                s.note("  after ⌃Tab: tab \((s.window?.selectedIndex ?? -1) + 1)  expect 2")
                Settings.windowsKeys = false
            }),
            (0.2, "global shortcut registers", {
                GlobalHotKey.preset = .controlOptionE
                GlobalHotKey.shared.apply()
                s.note("  ⌃⌥E registered: \(GlobalHotKey.shared.isRegistered)")
                GlobalHotKey.preset = .off
                GlobalHotKey.shared.apply()
            }),
        ])
    }

    /// Search in a folder (not indexed by Spotlight: the name walk), back to the folder, the whole
    /// Mac; CPU while results are shown and after leaving them.
    static func search(_ s: Scenario) {
        let base = s.makeFiles(["Отчёт 2024.txt", "report.txt", "other.txt"])
        s.makeFiles(["отчет старый.md"], in: "sub/deep")
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        func field() -> NSSearchField? { s.find(NSSearchField.self, in: s.window?.window?.contentView) }
        func type(_ text: String) {
            guard let field = field(), let action = field.action else { s.note("  (no search field)"); return }
            field.stringValue = text
            NSApp.sendAction(action, to: field.target, from: field)
        }
        func status() -> String {
            (s.window?.window?.contentView).map { v in s.findAll(NSTextField.self, in: v) }?
                .first { $0.stringValue.hasPrefix("Найдено") || $0.stringValue.contains("элемент") || $0.stringValue.hasPrefix("Введите") }?.stringValue ?? "?"
        }
        func names() -> [String] {
            guard let table = s.table else { return [] }
            return (0..<table.numberOfRows).compactMap { (table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue }.sorted()
        }
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        var cpuStart = 0.0
        Settings.searchWholeMac = false
        s.run([
            (0.8, "type «отчёт»", { type("отчёт") }),
            (2.5, "results", {
                s.note("  \(s.window?.selectedTab.title ?? "?") | \(status())")
                s.note("  \(names())  expect Отчёт 2024.txt, отчет старый.md")
                let folderColumn = s.table?.tableColumn(withIdentifier: .init("folder"))
                s.note("  folder column shown: \(folderColumn?.isHidden == false)")
                cpuStart = cpuSeconds()
            }),
            (5.0, "CPU with results on screen (5 s)", { s.note(String(format: "  %.1f%% of one core", (cpuSeconds() - cpuStart) / 5 * 100)) }),
            (0.1, "clear the field", { type("") }),
            (0.8, "back in the folder", {
                s.note("  \(s.window?.selectedTab.title ?? "?"), folder column hidden: \(s.table?.tableColumn(withIdentifier: .init("folder"))?.isHidden == true)")
                cpuStart = cpuSeconds()
            }),
            (5.0, "CPU after leaving the results (5 s)", { s.note(String(format: "  %.1f%% of one core", (cpuSeconds() - cpuStart) / 5 * 100)) }),
            (0.1, "type again, then Esc", {
                type("отч")
            }),
            (1.0, "Esc", {
                s.window?.window?.makeFirstResponder(field())
                s.key("\u{1b}", code: 53)
            }),
            (0.6, "after Esc", {
                let focus = s.window?.window?.firstResponder
                s.note("  field: «\(field()?.stringValue ?? "?")», \(s.window?.selectedTab.title ?? "?"), focus in the list: \(focus === s.table || focus === s.grid)  expect «», the folder, true")
            }),
            (0.1, "whole Mac, 1 letter", { Settings.searchWholeMac = true; type("W") }),
            (0.8, "too short", { s.note("  \(status())") }),
            (0.1, "whole Mac: «WinEx»", {
                cpuStart = cpuSeconds()
                type("WinEx")
            }),
            (4.0, "results", {
                s.note("  \(status()), CPU for the search: \(String(format: "%.2f", cpuSeconds() - cpuStart)) s")
                s.note("  includes this project: \(names().contains("WinEx"))")
                Settings.searchWholeMac = false
            }),
        ])
    }

    /// Copy with the progress window (pause, resume), then a move with name clashes decided per file.
    static func fileOps(_ s: Scenario) {
        let fm = FileManager.default
        let from = s.makeFiles(["a.txt", "b.txt", "c.txt", "d.txt"], in: "from")
        let to = s.makeFiles([], in: "to")
        let target = s.makeFiles(["a.txt", "b.txt", "c.txt"], in: "target")
        let big = from.appendingPathComponent("big.bin")
        fm.createFile(atPath: big.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: big) {
            let chunk = Data(repeating: 0x5A, count: 8 << 20)
            for _ in 0..<40 { handle.write(chunk) }  // 320 MB
            try? handle.close()
        }
        FileOperation.cloneFiles = false
        FileOperation.slowDownForTesting = 0.012

        func window(titled test: (String) -> Bool) -> NSWindow? { NSApp.windows.first { $0.isVisible && test($0.title) } }
        var progressWindow: NSWindow? { window { $0.contains("%") || $0.contains("Подготовка") || $0.contains("Приостановлено") } }
        var conflictWindow: NSWindow? { window { $0 == "Замена или пропуск файлов" } }
        func texts(_ view: NSView?) -> [String] {
            guard let view else { return [] }
            var result: [String] = []
            if let field = view as? NSTextField, !field.stringValue.isEmpty { result.append(field.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { result.append("[\(button.title)]") }
            return result + view.subviews.flatMap(texts)
        }
        func snapshot(_ window: NSWindow?, _ name: String) {
            guard let view = window?.contentView else { return }
            let data = view.dataWithPDF(inside: view.bounds)
            guard let image = NSImage(data: data) else { return }
            let size = NSSize(width: view.bounds.width * 2, height: view.bounds.height * 2)
            let png = NSImage(size: size, flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill(); rect.fill()
                image.draw(in: rect)
                return true
            }
            guard let tiff = png.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: s.output.appendingPathComponent(name))
        }
        func press(_ title: String, in view: NSView?) -> Bool {
            guard let view else { return false }
            if let button = view as? NSButton, button.title == title || button.toolTip == title { button.performClick(nil); return true }
            return view.subviews.contains { press(title, in: $0) }
        }
        func waitUntil(_ condition: @escaping () -> Bool, then next: @escaping () -> Void, tries: Int = 300) {
            if condition() || tries == 0 { next(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitUntil(condition, then: next, tries: tries - 1) }
        }

        s.run([
            (0.3, "copy 320 MB", { FileOps.transfer([big], to: to, copy: true) }),
            (1.5, "progress window", {
                s.note("  \(progressWindow?.title ?? "(no progress window)")")
                s.note("  \(texts(progressWindow?.contentView).joined(separator: " | "))")
                snapshot(progressWindow, "progress.png")
            }),
            (0.1, "fewer / more details", {
                let full = progressWindow?.frame.height ?? 0
                _ = press("Меньше подробностей", in: progressWindow?.contentView)
                let small = progressWindow?.frame.height ?? 0
                _ = press("Больше подробностей", in: progressWindow?.contentView)
                s.note("  height: \(Int(full)) → \(Int(small)) → \(Int(progressWindow?.frame.height ?? 0))  expect smaller, then back")
            }),
            (0.1, "pause", { if !press("Приостановить", in: progressWindow?.contentView) { s.note("  (no pause button)") } }),
            (0.8, "paused?", {
                let first = progressWindow?.title ?? "-"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    s.note("  \(first) → \(progressWindow?.title ?? "-")  expect the same percentage (paused)")
                    snapshot(progressWindow, "paused.png")
                    // Full speed for the rest: the next steps expect the copy to be over
                    FileOperation.slowDownForTesting = 0
                    _ = press("Продолжить", in: progressWindow?.contentView)
                }
            }),
            (1.0, "wait for the copy", {
                waitUntil({ progressWindow == nil }) {
                    let size = (try? fm.attributesOfItem(atPath: to.appendingPathComponent("big.bin").path)[.size] as? Int) ?? 0
                    s.note("  copied: \(size / 1_048_576) MB, window gone: \(progressWindow == nil), undo: \(FileUndo.manager.undoActionName)")
                    FileOperation.slowDownForTesting = 0
                    // Move with clashes: a, b, c exist in target; d doesn't
                    FileOps.transfer(["a.txt", "b.txt", "c.txt", "d.txt"].map { from.appendingPathComponent($0) }, to: target, copy: false)
                }
            }),
            (1.5, "conflict dialog", {
                s.note("  \(texts(conflictWindow?.contentView).joined(separator: " | "))")
                snapshot(conflictWindow, "conflict.png")
                _ = press("Решить для каждого файла", in: conflictWindow?.contentView)
            }),
            (0.5, "decide for each", {
                snapshot(conflictWindow, "each.png")
                let popups = (conflictWindow?.contentView).map { v in s.findAll(NSPopUpButton.self, in: v) } ?? []
                // a: replace, b: skip, c: keep both
                for (popup, index) in zip(popups, [0, 1, 2]) { popup.selectItem(at: index) }
                s.note("  rows: \(popups.count), popups: \(popups.map { "\($0.convert($0.bounds, to: nil))" }), window: \(conflictWindow?.frame.size ?? .zero)")
                s.note("  \(texts(conflictWindow?.contentView).suffix(3).joined(separator: " | "))")
                _ = press("Продолжить", in: conflictWindow?.contentView)
            }),
            (1.0, "result", {
                s.note("  target: \(s.files(in: target))  expect a, b, c, c - копия, d")
                s.note("  from: \(s.files(in: from).filter { $0 != "big.bin" })  expect b (skipped)")
                FileOperation.cloneFiles = true
            }),
        ])
    }

    /// An icon whose monitor isn't connected shows on the main one; its place is kept for when the
    /// monitor comes back. (Pretends the second monitor's icons belong to a monitor that's gone.)
    static func monitorGone(_ s: Scenario) {
        let controller = DesktopController()
        controller.show()
        func views() -> [DesktopView] { NSApp.windows.compactMap { $0.contentView as? DesktopView } }
        func counts() -> String { views().forEach { $0.displayIfNeeded() }; return views().map { "\($0.window?.screen?.localizedName ?? "?"): \($0.subviews.count)" }.joined(separator: ", ") }
        var moved: [String] = []
        s.run([
            (1.5, "start", { s.note("  icons: \(counts())") }),
            (0.2, "second monitor's icons → a monitor that isn't connected", {
                guard let main = views().first(where: { $0.window?.screen == NSScreen.screens.first }),
                      let second = NSScreen.screens.dropFirst().first?.displayUUID else { s.note("  (one monitor only)"); return }
                let fm = FileManager.default
                let names = (try? fm.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? []
                for name in names {
                    guard let place = main.layout.place(for: name), place.screenID == second else { continue }
                    main.layout.setPlace(DesktopLayout.Place(point: place.point, screenID: "GONE"), for: name)
                    moved.append(name)
                }
                views().forEach { $0.reloadShared() }
                s.note("  moved \(moved.count); icons: \(counts())  expect all on the main monitor")
                let kept = moved.compactMap { main.layout.place(for: $0)?.screenID }
                s.note("  stored monitor kept: \(kept.allSatisfy { $0 == "GONE" } && !kept.isEmpty)")
                // Put them back (the layout lives in the scenario's own settings anyway)
                for name in moved {
                    if let place = main.layout.place(for: name) {
                        main.layout.setPlace(DesktopLayout.Place(point: place.point, screenID: second), for: name)
                    }
                }
                views().forEach { $0.reloadShared() }
                s.note("  back: \(counts())")
                controller.hide()
            }),
        ])
    }

    /// Real-mouse check, driven by `scripts/mouse-drag-check.swift` (run with the user's consent):
    /// the app places its window and writes where to grab it and where the close button is — only
    /// after checking that at those points the topmost window on screen is this one; the script
    /// drags with the real mouse and clicks close; then a new window opens and its place is logged.
    static func mouseDrag(_ s: Scenario) {
        let app = AppDelegate.shared
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        func cg(_ p: NSPoint) -> String { "\(Int(p.x)) \(Int(mainHeight - p.y))" }
        func isOurs(_ p: NSPoint, _ window: NSWindow) -> Bool {
            NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0) == window.windowNumber
        }
        func write(_ name: String, _ text: String) {
            try? text.write(to: s.output.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: s.output.appendingPathComponent(name).path) }
        func wait(for name: String, then next: @escaping () -> Void, tries: Int = 300) {
            if exists(name) { next(); return }
            guard tries > 0 else { s.note("  (timed out waiting for \(name))"); s.run([]); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait(for: name, then: next, tries: tries - 1) }
        }
        func describe(_ w: NSWindow?) -> String {
            guard let w else { return "-" }
            return "\(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))×\(Int(w.frame.height)) on \(w.screen?.localizedName ?? "?")"
        }
        guard let window = s.window?.window, let second = NSScreen.screens.dropFirst().first else {
            s.note("  (no window or one monitor only)"); s.run([]); return
        }
        window.setFrame(NSRect(x: 500, y: 400, width: 900, height: 600), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let grab = NSPoint(x: window.frame.maxX - 120, y: window.frame.maxY - 26)
            let target = NSPoint(x: second.frame.midX, y: second.frame.midY + 200)
            guard isOurs(grab, window) else { s.note("  another window covers the grab point — aborted"); write("abort", ""); s.run([]); return }
            s.note("  opened: \(describe(window))")
            write("grab.txt", "\(cg(grab)) \(cg(target))")
            wait(for: "dragged") {
                s.note("  after the mouse drag: \(describe(window))  saved on: \(WindowPlacement.saved.flatMap { p in NSScreen.screens.first { $0.displayUUID == p.screenID }?.localizedName } ?? "-")")
                guard let close = window.standardWindowButton(.closeButton) else { s.run([]); return }
                let frame = close.convert(close.bounds, to: nil)
                let point = window.convertPoint(toScreen: NSPoint(x: frame.midX, y: frame.midY))
                guard isOurs(point, window) else { s.note("  close button covered — aborted"); write("abort", ""); s.run([]); return }
                write("close.txt", cg(point))
                wait(for: "closed") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        s.note("  windows after the click on close: \(app.windowControllers.count)")
                        // Like a click on the Dock icon with no windows
                        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            s.note("  reopened: \(describe(s.window?.window))  expect on \(second.localizedName)")
                            s.run([])
                        }
                    }
                }
            }
        }
    }

    /// A window closed on the second monitor: the next one must open there. Logs every save.
    static func placementSecondScreen(_ s: Scenario) {
        let app = AppDelegate.shared
        guard let second = NSScreen.screens.dropFirst().first else { s.note("  (one monitor only)"); s.run([]); return }
        let target = CGRect(x: second.visibleFrame.minX + 200, y: second.visibleFrame.minY + 200, width: 900, height: 600)
        func saved() -> String {
            guard let p = WindowPlacement.saved else { return "-" }
            let screen = NSScreen.screens.first { $0.displayUUID == p.screenID }?.localizedName ?? p.screenID
            return "\(Int(p.frame.minX)),\(Int(p.frame.minY)) \(Int(p.frame.width))×\(Int(p.frame.height)) on \(screen)"
        }
        let main = CGRect(x: 300, y: 300, width: 640, height: 700)
        var onSecond: ExplorerWindowController?
        // Like with "WinEx instead of Finder": the WinEx desktop is on the main monitor
        let desktop = DesktopController()
        if ProcessInfo.processInfo.environment["WINEX_WITH_DESKTOP"] != nil { desktop.show() }
        s.run([
            (0.5, "window A on the main monitor, window B on the second", {
                s.window?.window?.setFrame(main, display: true)
                onSecond = app.openWindow(at: s.sandbox)
                onSecond?.window?.setFrame(target, display: true)
                s.note("  saved: \(saved())")
            }),
            (0.5, "close B (A becomes active by itself)", { onSecond?.window?.performClose(nil) }),
            (0.5, "after close", { s.note("  saved: \(saved())  expect B on \(second.localizedName)  windows: \(app.windowControllers.count)") }),
            (0.2, "open a window while A is open", {
                let w = app.openWindow(at: s.sandbox).window
                s.note("  cascades from A: \(w?.frame ?? .zero) on \(w?.screen?.localizedName ?? "?")")
            }),
            (0.5, "close A and the new one; move a last window to the second monitor and close it", {
                app.windowControllers.forEach { $0.window?.performClose(nil) }
                let last = app.openWindow(at: s.sandbox).window
                last?.setFrame(target, display: true)
                last?.performClose(nil)
            }),
            (0.5, "open after all closed", {
                // A click on the desktop makes it the key window (it's on the main monitor)
                NSApp.windows.first { $0 is DesktopWindow }?.makeKeyAndOrderFront(nil)
                // Opened while another app is active, like a click on the Dock icon
                if ProcessInfo.processInfo.environment["WINEX_INACTIVE"] != nil { NSApp.deactivate() }
                s.note("  key: \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none"), NSScreen.main: \(NSScreen.main?.localizedName ?? "?")")
                let w = app.openWindow(at: s.sandbox).window
                s.note("  new: \(w?.frame ?? .zero) on \(w?.screen?.localizedName ?? "?")  expect \(target) on \(second.localizedName)")
            }),
            (0.5, "a moment later", {
                let w = s.window?.window
                s.note("  new: \(w?.frame ?? .zero) on \(w?.screen?.localizedName ?? "?")")
                desktop.hide()
            }),
        ])
    }

    /// Settings ▸ "Сбросить рабочий стол как в Finder…": Cancel keeps the layout, Reset takes Finder's.
    static func desktopReset(_ s: Scenario) {
        let desktop = DesktopController()
        desktop.show()
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        func stored() -> String {
            guard let data = AppDefaults.store.data(forKey: "desktopLayout"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "-" }
            return "iconSize=\(json["iconSize"] ?? "?") positions=\((json["positions"] as? [String: Any])?.count ?? 0)"
        }
        func settingsWindow() -> NSWindow? { NSApp.windows.first { $0.title == "Настройки WinEx" } }
        func press(_ title: String, in view: NSView?) -> Bool {
            guard let view else { return false }
            if let button = view as? NSButton, button.title == title { button.performClick(nil); return true }
            return view.subviews.contains { press(title, in: $0) }
        }
        func answer(_ title: String) {
            guard let sheet = settingsWindow()?.attachedSheet else { s.note("  (no confirmation shown)"); return }
            s.note("  asked: \(sheet.contentView.flatMap { v in s.find(NSTextField.self, in: v)?.stringValue } ?? "?")")
            if !press(title, in: sheet.contentView) { s.note("  (no \(title) button)") }
        }
        s.run([
            (1.0, "scramble the WinEx layout", {
                s.note("  imported: \(stored())")
                let scrambled: [String: Any] = ["positions": ["x": [0.5, 0.5]], "iconSize": 2, "autoArrange": false,
                                                "alignToGrid": true, "showIcons": true, "sortKey": "name", "importedFromFinder": true]
                AppDefaults.store.set(try? JSONSerialization.data(withJSONObject: scrambled), forKey: "desktopLayout")
                s.note("  scrambled: \(stored())")
                AppDelegate.shared.showSettings(nil)
            }),
            (0.5, "settings layout", {
                guard let stack = settingsWindow()?.contentView as? NSStackView else { s.note("  (no stack)"); return }
                for v in stack.arrangedSubviews {
                    let title = (v as? NSButton)?.title ?? (v as? NSTextField)?.stringValue.prefix(30).description ?? "—"
                    s.note("  \(Int(v.frame.minY))…\(Int(v.frame.maxY)) x\(Int(v.frame.minX)) w\(Int(v.frame.width)) \(title)")
                }
                s.note("  window content: \(Int(stack.bounds.width))×\(Int(stack.bounds.height))")
            }),
            (0.5, "press reset", { if !press("Сбросить рабочий стол как в Finder…", in: settingsWindow()?.contentView) { s.note("  (no button)") } }),
            (0.5, "Cancel", { answer("Отмена") }),
            (0.5, "check", { s.note("  after cancel: \(stored())  expect scrambled") }),
            (0.2, "press reset", { _ = press("Сбросить рабочий стол как в Finder…", in: settingsWindow()?.contentView) }),
            (0.5, "Reset", { answer("Сбросить") }),
            (0.5, "check", {
                let finder = FinderDesktopLayout.iconPlaces(in: desktopURL, screenSizes: NSScreen.screens.map(\.frame.size))
                s.note("  after reset (WinEx desktop off): \(stored())  expect - (imported on next start)")
                AppDefaults.store.set(try? JSONSerialization.data(withJSONObject: ["iconSize": 2, "importedFromFinder": true, "positions": [:]]), forKey: "desktopLayout")
                desktop.resetToFinder()
                s.note("  reset of a running desktop: \(stored())  expect like imported (Finder knows \(finder.count) places, some gone)")
                desktop.hide()
            }),
        ])
    }

    /// Two windows moved around; after both close, a new window opens where the last used one was.
    static func placement(_ s: Scenario) {
        let app = AppDelegate.shared
        let visible = NSScreen.screens.first?.visibleFrame ?? .zero
        let first = CGRect(x: visible.minX + 40, y: visible.minY + 60, width: 800, height: 500)
        let second = CGRect(x: visible.minX + 300, y: visible.minY + 120, width: 900, height: 560)
        var other: ExplorerWindowController?
        func describe(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-" }
        s.run([
            (0.5, "move first window", { s.window?.window?.setFrame(first, display: true) }),
            (0.3, "open a second window, move it", {
                other = app.openWindow(at: s.sandbox)
                other?.window?.setFrame(second, display: true)
            }),
            (0.3, "focus the first again, then the second", {
                s.window?.window?.makeKeyAndOrderFront(nil)
                other?.window?.makeKeyAndOrderFront(nil)
            }),
            (0.3, "close all", { app.windowControllers.forEach { $0.window?.close() } }),
            (0.3, "open a new window", {
                let frame = app.openWindow(at: s.sandbox).window?.frame
                s.note("  new: \(describe(frame))  expect \(describe(second))")
            }),
            (0.3, "a second new window cascades", {
                let frame = app.openWindow(at: s.sandbox).window?.frame
                s.note("  cascaded: \(describe(frame))  expect shifted, 900×560")
            }),
        ])
    }

    /// Shows the WinEx desktop, selects everything (⌘A) and saves a picture of it as desktop.png.
    static func desktop(_ s: Scenario) {
        let controller = DesktopController()
        controller.show()
        var view: DesktopView? { NSApp.windows.lazy.compactMap { $0.contentView as? DesktopView }.first }
        s.run([
            (2.0, "⌘A", {
                guard let view, let window = view.window,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "a",
                                                   charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) else { s.note("  (no desktop)"); return }
                view.keyDown(with: event)
                s.note("  icons: \(view.subviews.count) subviews")
            }),
            (0.5, "Quick Look transition picture", {
                let views = NSApp.windows.compactMap { $0.contentView as? DesktopView }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? []
                for name in names where ["png", "jpg", "jpeg", "webp", "pdf"].contains((name as NSString).pathExtension.lowercased()) {
                    let url = DesktopView.desktopURL.appendingPathComponent(name) as NSURL
                    var rect = NSRect.zero
                    guard let view = views.first(where: { $0.previewPanel(nil, sourceFrameOnScreenFor: url) != .zero }),
                          let image = view.previewPanel(nil, transitionImageFor: url, contentRect: &rect) as? NSImage,
                          let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
                    let corner = rep.colorAt(x: 0, y: 0)?.alphaComponent ?? -1
                    let middle = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? -1
                    s.note("  \(name): corner alpha \(corner), middle alpha \(middle)  expect 0, 1")
                    try? rep.representation(using: .png, properties: [:])?.write(to: s.output.appendingPathComponent("transition.png"))
                    break
                }
            }),
            (1.0, "snapshot of every monitor", {
                let views = NSApp.windows.compactMap { $0.contentView as? DesktopView }
                for view in views {
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = view.window?.screen?.localizedName ?? "?"
                    s.note("  \(name): \(view.subviews.count) icons")
                    try? rep.representation(using: .png, properties: [:])?.write(to: s.output.appendingPathComponent("desktop-\(name).png"))
                }
                controller.hide()
            }),
        ])
    }

    /// Does the window server count a nearly transparent window as "there" (so it gets clicks)?
    /// Asks it for the window under a point — no real mouse involved.
    static func hitTest(_ s: Scenario) {
        final class LayerFill: NSView {
            var alpha: CGFloat = 0
            override var wantsUpdateLayer: Bool { true }
            override func updateLayer() { layer?.backgroundColor = NSColor(white: 0, alpha: alpha).cgColor }
        }
        final class DrawFill: NSView {
            override func draw(_ dirtyRect: NSRect) { NSColor(white: 0, alpha: 0.005).setFill(); dirtyRect.fill(using: .copy) }
        }
        let clear = LayerFill(), layer = LayerFill()
        layer.alpha = 0.005
        let cases: [(String, NSView)] = [("clear layer (control)", clear), ("layer 0.005", layer), ("draw 0.005", DrawFill())]
        let screen = NSScreen.screens.first?.frame ?? .zero
        let windows = cases.enumerated().map { n, c -> NSWindow in
            let w = NSWindow(contentRect: NSRect(x: screen.minX + 20 + CGFloat(n) * 120, y: screen.minY + 200, width: 100, height: 100),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentView = c.1
            w.orderFront(nil)
            return w
        }
        s.run([
            (1.0, "query", {
                for (w, c) in zip(windows, cases) {
                    let hit = NSWindow.windowNumber(at: NSPoint(x: w.frame.midX, y: w.frame.midY), belowWindowWithWindowNumber: 0)
                    s.note("  \(c.0): \(hit == w.windowNumber ? "catches clicks" : "clicks pass through")")
                }
                windows.forEach { $0.orderOut(nil) }
            }),
        ])
    }

    /// ⌘Z / ⇧⌘Z for rename, trash, move, new folder, tags; ⌘Z in a text field undoes typing.
    static func undo(_ s: Scenario) {
        let base = s.makeFiles(["a.txt", "b.txt", "dir/"])
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        // File work of undo / redo runs in the background: wait for it before looking at the files
        func undo() { s.key("z", code: 6, modifiers: .command, viaMenu: true); FileUndo.waitForFileWork() }
        func redo() { s.key("Z", code: 6, modifiers: [.command, .shift], viaMenu: true); FileUndo.waitForFileWork() }
        s.run([
            (0.8, "start", { s.note("  \(s.files())") }),
            (0.1, "rename a.txt → renamed.txt", {
                s.select("a.txt"); s.send("renameSelected:")
                if let editor = s.window?.window?.firstResponder as? NSTextView {
                    editor.selectAll(nil); editor.insertText("renamed.txt", replacementRange: editor.selectedRange()); editor.insertNewline(nil)
                }
            }),
            (0.5, "⌘Z", { undo(); s.note("  \(s.files())  expect a.txt") }),
            (0.5, "⇧⌘Z", { redo(); s.note("  \(s.files())  expect renamed.txt") }),
            (0.5, "⌘Z", { undo() }),
            (0.5, "trash b.txt", { s.select("b.txt"); s.send("moveToTrash:") }),
            (1.2, "⌘Z", { undo(); s.note("  \(s.files())  expect b.txt back") }),
            (0.5, "cut a.txt, paste into dir", { s.select("a.txt"); s.send("cut:"); FileClipboard.shared.paste(into: base.appendingPathComponent("dir")) }),
            (1.0, "⌘Z", { undo(); s.note("  \(s.files()) dir=\(s.files(in: base.appendingPathComponent("dir")))  expect a.txt back") }),
            (0.5, "tag b.txt", { FileTags.toggle(FileTags.Tag(name: "Красный", color: 6), on: [base.appendingPathComponent("b.txt")], add: true) }),
            (0.3, "⌘Z", { undo(); s.note("  tags: \(FileTags.tags(of: base.appendingPathComponent("b.txt")).map(\.name))  expect []") }),
            (0.3, "type in the address bar, ⌘Z", {
                s.send("focusPathField:")
                guard let editor = s.window?.window?.firstResponder as? NSTextView else { s.note("  (no editor)"); return }
                editor.moveToEndOfDocument(nil)
                for (ch, code) in [("x", UInt16(7)), ("y", 16)] { s.key(ch, code: code) }
                undo()
                s.note("  address: …\(editor.string.suffix(6))  expect no «xy»")
            }),
        ])
    }

    /// ⇧⌘N → type a name → Return: the new folder stays selected (table and icons).
    static func newFolder(_ s: Scenario) {
        let base = s.makeFiles(["file.txt"])
        s.window?.navigate(to: base)
        func typeName(_ name: String) {
            guard let editor = s.window?.window?.firstResponder as? NSTextView else { s.note("  (not editing)"); return }
            editor.selectAll(nil)
            editor.insertText(name, replacementRange: editor.selectedRange())
            s.key("\r", code: 36)
        }
        s.run([
            (0.3, "table", { s.setViewMode(.details) }),
            (0.5, "⇧⌘N", { s.key("N", code: 45, modifiers: [.command, .shift], viaMenu: true); s.note("  editing: \(s.editingText)") }),
            (0.5, "type «Проекты» + Return", { typeName("Проекты") }),
            (0.8, "check", { s.note("  selected: \(s.selectedNames)  expect [Проекты]") }),
            (0.2, "icons", { s.setViewMode(.mediumIcons) }),
            (0.5, "⇧⌘N", { s.key("N", code: 45, modifiers: [.command, .shift], viaMenu: true) }),
            (0.5, "type «Архив» + Return", { typeName("Архив") }),
            (0.8, "check", { s.note("  selected: \(s.selectedNames)  expect [Архив]") }),
        ])
    }

    /// Clicking the name of the already selected item renames it after a pause; other clicks don't.
    static func slowClick(_ s: Scenario) {
        let base = s.makeFiles(["alpha.txt", "beta.txt", "folder/"])
        s.window?.navigate(to: base)
        func point(_ name: String, label: Bool) -> (NSView, NSPoint)? {
            guard let grid = s.grid else { return nil }
            for i in 0..<grid.count {
                guard let item = grid.item(at: IndexPath(item: i, section: 0)) as? FileGridItem,
                      item.textField?.stringValue.hasSuffix(name) == true,
                      let frame = grid.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame else { continue }
                // The name's area (from the item's label frame) or the icon's middle
                if label, let field = item.textField {
                    let rect = field.convert(field.bounds, to: grid)
                    return (grid, NSPoint(x: rect.midX, y: rect.midY - 4))
                }
                return (grid, NSPoint(x: frame.midX, y: frame.minY + 40))
            }
            s.note("  (\(name) not found)")
            return nil
        }
        func click(_ name: String, label: Bool, clicks: Int = 1) {
            if let (view, p) = point(name, label: label) { s.click(view, at: p, clicks: clicks) }
        }
        s.run([
            (0.3, "icons", { s.setViewMode(.mediumIcons) }),
            (0.8, "click alpha icon", { click("alpha.txt", label: false) }),
            (1.0, "click alpha label", { click("alpha.txt", label: true); s.note("  right away: \(s.editingText)  expect -") }),
            (0.8, "later", { s.note("  editing: \(s.editingText)  expect alpha.txt"); s.window?.window?.makeFirstResponder(s.grid) }),
            (0.4, "click beta label (not selected)", { click("beta.txt", label: true) }),
            (1.0, "later", { s.note("  editing: \(s.editingText)  expect -") }),
            (0.1, "select folder, double-click its label", {
                click("folder", label: false)
                click("folder", label: true); click("folder", label: true, clicks: 2)
            }),
            (1.0, "later", { s.note("  location: \(s.window?.selectedTab.title ?? "?") editing: \(s.editingText)  expect folder, -") }),
        ])
    }

    /// Opening / reloading a 10 000-file folder: how long, and how long the UI stalls.
    static func perf(_ s: Scenario) {
        let big = s.sandbox.appendingPathComponent("big")
        try? FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 1...10_000 { FileManager.default.createFile(atPath: big.appendingPathComponent("file-\(i).txt").path, contents: nil) }
        s.note(String(format: "after launch: %.0f MB", s.footprintMB))

        // Watchdog on a background thread: every 5 ms it asks the main thread to answer; the longest
        // wait is the longest UI stall (a timer on the main thread can't see its own blockage)
        let watchdog = StallWatchdog()
        watchdog.start()
        var worst: TimeInterval { watchdog.worst }
        func loaded() -> Int { s.table?.numberOfRows ?? 0 }
        func measure(_ title: String, count: Int = 10_000, _ action: @escaping () -> Void, then next: @escaping () -> Void) {
            watchdog.reset()
            let start = Date()
            action()
            func poll() {
                if loaded() == count || Date().timeIntervalSince(start) > 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        s.note(String(format: "%@: %.0f ms until listed, longest UI stall %.0f ms", title, Date().timeIntervalSince(start) * 1000 - 50, worst * 1000))
                        next()
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
                }
            }
            poll()
        }
        s.setViewMode(.details)
        measure("open 10 000 files", { s.window?.navigate(to: big) }) {
            // A burst of 200 new files, like a copy in progress: wait until they're all listed
            measure("200 files added in a burst", count: 10_200, {
                for i in 1...200 { FileManager.default.createFile(atPath: big.appendingPathComponent("new-\(i).txt").path, contents: nil) }
            }) {
                s.note(String(format: "in the big folder: %.0f MB", s.footprintMB))
                let desktop = DesktopController()
                desktop.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    s.note(String(format: "with the desktop (+5 s): %.0f MB", s.footprintMB))
                    desktop.hide()
                    watchdog.stop()
                    s.run([])
                }
            }
        }
    }
}
/// Measures how long the main thread takes to answer, from a background thread.
final class StallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var longest: TimeInterval = 0
    private var running = false

    var worst: TimeInterval { lock.withLock { longest } }
    func reset() { lock.withLock { longest = 0 } }

    func start() {
        running = true
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let delay = Date().timeIntervalSince(sent)
                lock.withLock { longest = max(longest, delay) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func stop() { lock.withLock { running = false } }
}
#endif
