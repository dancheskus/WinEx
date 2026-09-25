#if DEBUG
import AppKit

/// In-app test scenarios (debug builds only). Run with `scripts/run-scenario.sh <name>`:
/// the app starts with `WINEX_SCENARIO=<name>` and `WINEX_SCENARIO_OUT=<dir>`, uses its own
/// settings store (see `AppDefaults`), drives itself with in-process events only — never the real
/// mouse or keyboard — writes `log.txt` after every step and quits.
///
/// Helpers never force-unwrap: a failed lookup is logged, not a crash (a crash would pop the
/// macOS "quit unexpectedly" dialog on the user's screen).
@MainActor
final class Scenario {
    nonisolated static var isRequested: Bool { ProcessInfo.processInfo.environment["WINEX_SCENARIO"] != nil }

    typealias Step = (delay: Double, title: String, action: () -> Void)

    let output: URL
    /// A fresh folder for the scenario's files.
    let sandbox: URL
    private var log = ""

    private init(output: URL) {
        self.output = output
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("winex-scenario-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    /// Called from `applicationDidFinishLaunching`.
    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["WINEX_SCENARIO"], let out = env["WINEX_SCENARIO_OUT"] else { return }
        let scenario = Scenario(output: URL(fileURLWithPath: out))
        guard let body = Scenarios.all[name] else {
            scenario.note("unknown scenario \(name); known: \(Scenarios.all.keys.sorted())")
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSApp.activate(ignoringOtherApps: true)
            body(scenario)
        }
    }

    // MARK: Log

    func note(_ line: String) {
        log += line + "\n"
        try? log.write(to: output.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }

    /// Runs steps one after another, logs each, then cleans up and quits.
    func run(_ steps: [Step], index: Int = 0) {
        guard index < steps.count else {
            note("done")
            try? FileManager.default.removeItem(at: sandbox)
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + steps[index].delay) { [self] in
            steps[index].action()
            note("[\(index)] \(steps[index].title)")
            run(steps, index: index + 1)
        }
    }

    // MARK: Fixtures

    @discardableResult
    func makeFiles(_ names: [String], in folder: String? = nil) -> URL {
        let dir = folder.map { sandbox.appendingPathComponent($0) } ?? sandbox
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            if name.hasSuffix("/") {
                try? FileManager.default.createDirectory(at: dir.appendingPathComponent(String(name.dropLast())), withIntermediateDirectories: true)
            } else {
                FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(name.utf8))
            }
        }
        return dir
    }

    func files(in folder: URL? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (folder ?? sandbox).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: App access

    var window: ExplorerWindowController? { AppDelegate.shared.windowControllers.first }

    func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        return (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { findAll(type, in: $0) }
    }

    var table: FileTableView? { find(FileTableView.self, in: window?.window?.contentView) }
    var grid: FileCollectionView? { find(FileCollectionView.self, in: window?.window?.contentView) }

    func setViewMode(_ mode: ViewMode) {
        let item = NSMenuItem()
        item.tag = mode.rawValue
        window?.selectViewMode(item)
    }

    /// Text being edited in the key window ("-" when nothing is).
    var editingText: String { (window?.window?.firstResponder as? NSTextView)?.string ?? "-" }

    // MARK: Events (in-process only)

    /// A click at a point of `view`; the mouse-up is queued first so tracking loops can't hang.
    func click(_ view: NSView, at local: NSPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = view.window else { note("  (click: view has no window)"); return }
        let point = view.convert(local, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: nil, inMode: .default, dequeue: true) { window.sendEvent(queued) }
    }

    /// A key press. With `viaMenu`, goes through the main menu like a shortcut; `characters` are
    /// what a real keyboard sends (e.g. "N" for ⇧⌘N).
    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], viaMenu: Bool = false) {
        guard let window = NSApp.keyWindow ?? self.window?.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        if viaMenu {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) != true { note("  (no menu item for \(characters))") }
        } else if !modifiers.intersection([.command, .control]).isEmpty {
            // Through the application, like the keyboard: key equivalents go to the menus first
            NSApp.sendEvent(event)
        } else {
            window.sendEvent(event)
        }
    }

    func send(_ action: String) {
        if !NSApp.sendAction(Selector((action)), to: nil, from: nil) { note("  (nobody handled \(action))") }
    }

    /// Selects a row / icon by file name in the current view.
    func select(_ name: String) {
        if let table, !(table.enclosingScrollView?.isHidden ?? true) {
            let row = (0..<table.numberOfRows).first { (table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == name }
            window?.window?.makeFirstResponder(table)
            if let row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { note("  (\(name) not in table)") }
        } else if let grid {
            let index = (0..<grid.count).first { (grid.item(at: IndexPath(item: $0, section: 0)) as? FileGridItem)?.textField?.stringValue.hasSuffix(name) == true }
            window?.window?.makeFirstResponder(grid)
            if let index { grid.setSelection([index], anchor: index) } else { note("  (\(name) not in grid)") }
        }
    }

    /// Names shown in the table, sorted.
    func names() -> [String] {
        guard let table else { return [] }
        return (0..<table.numberOfRows).compactMap { (table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue }.sorted()
    }

    /// Names selected in the current view.
    var selectedNames: [String] {
        if let table, !(table.enclosingScrollView?.isHidden ?? true) {
            return table.selectedRowIndexes.compactMap { (table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue }
        }
        guard let grid else { return [] }
        return grid.selectedIndexes.compactMap { (grid.item(at: IndexPath(item: $0, section: 0)) as? FileGridItem)?.textField?.stringValue }
    }

    /// Resident memory of this process (phys_footprint), in MB.
    var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
#endif
