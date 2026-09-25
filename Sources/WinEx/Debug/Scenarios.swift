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
    ]

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
        FileOperation.slowDownForTesting = 0.004

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
            let grab = NSPoint(x: window.frame.maxX - 120, y: window.frame.maxY - TabBarView.height / 2)
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
                return (grid, NSPoint(x: frame.midX, y: label ? frame.maxY - 14 : frame.minY + 28))
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
