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
    ]

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
                let w = app.openWindow(at: s.sandbox).window
                s.note("  new: \(w?.frame ?? .zero) on \(w?.screen?.localizedName ?? "?")  expect \(target) on \(second.localizedName)")
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
                let finder = FinderDesktopLayout.iconCenters(in: desktopURL, screenSize: NSScreen.screens.first?.frame.size ?? .zero)
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
            (1.0, "snapshot", {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: s.output.appendingPathComponent("desktop.png"))
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
