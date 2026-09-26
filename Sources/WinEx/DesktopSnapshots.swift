import AppKit

/// Snapshots of the WinEx desktop: where every icon is (in fences and outside them), the fences
/// and portals, the icon size and sorting — saved as files, automatically (daily by default) or
/// on request, and restored with one click. Separate from the settings backup.
@MainActor
enum DesktopSnapshots {
    struct Snapshot: Equatable {
        let url: URL
        let date: Date
        let automatic: Bool
        let fences: Int
        let icons: Int
    }

    static let didChange = Notification.Name("WinExDesktopSnapshotsChanged")
    private static let fileExtension = "winexdesktop"
    private static var defaults: UserDefaults { AppDefaults.store }

    /// ~/Library/Application Support/WinEx/Desktop Snapshots (scenario runs: a temporary folder).
    static var folder: URL {
        #if DEBUG
        if Scenario.isRequested { return FileManager.default.temporaryDirectory.appendingPathComponent("winex-scenario-snapshots") }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WinEx/Desktop Snapshots")
    }

    // MARK: Settings

    /// Hours between automatic snapshots (0: none).
    static var intervalHours: Int {
        get { defaults.object(forKey: "desktopSnapshotHours") as? Int ?? 24 }
        set { defaults.set(newValue, forKey: "desktopSnapshotHours"); NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// Automatic snapshots kept (older ones go; ones made by hand stay).
    static var keep: Int {
        get { defaults.object(forKey: "desktopSnapshotKeep") as? Int ?? 30 }
        set { defaults.set(newValue, forKey: "desktopSnapshotKeep"); prune() }
    }

    static let intervals: [(hours: Int, title: String)] = [
        (0, L("Выключено")), (1, L("Каждый час")), (6, L("Каждые 6 часов")), (24, L("Ежедневно")), (168, L("Еженедельно")),
    ]

    // MARK: Snapshots

    static var all: [Snapshot] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == fileExtension }.compactMap(read).sorted { $0.date > $1.date }
    }

    private static func read(_ url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url),
              let file = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let date = file["date"] as? Date else { return nil }
        return Snapshot(url: url, date: date, automatic: file["automatic"] as? Bool ?? false,
                        fences: file["fences"] as? Int ?? 0, icons: file["icons"] as? Int ?? 0)
    }

    /// The desktop's arrangement as stored by WinEx now.
    private static var currentLayout: Data? { defaults.data(forKey: "desktopLayout") }

    /// Saves the current arrangement. Automatic ones are skipped when nothing changed since the last.
    @discardableResult
    static func take(automatic: Bool) -> Snapshot? {
        guard let layout = currentLayout else { return nil }
        if automatic, let last = all.first, let data = try? Data(contentsOf: last.url),
           let file = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           file["layout"] as? Data == layout {
            defaults.set(Date(), forKey: "desktopSnapshotLast")
            return nil
        }
        let counts = (try? JSONSerialization.jsonObject(with: layout) as? [String: Any]) ?? [:]
        let file: [String: Any] = [
            "date": Date(), "automatic": automatic, "layout": layout, "version": Updater.shared.currentVersion,
            "fences": (counts["fences"] as? [Any])?.count ?? 0, "icons": (counts["positions"] as? [String: Any])?.count ?? 0,
        ]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            var url = folder.appendingPathComponent("\(formatter.string(from: Date()))\(automatic ? "" : " ★").\(fileExtension)")
            // Two in the same second (a restore saves the current state first): numbered
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(formatter.string(from: Date()))\(automatic ? "" : " ★") \(n).\(fileExtension)")
                n += 1
            }
            try PropertyListSerialization.data(fromPropertyList: file, format: .binary, options: 0).write(to: url, options: .atomic)
            defaults.set(Date(), forKey: "desktopSnapshotLast")
            prune()
            NotificationCenter.default.post(name: didChange, object: nil)
            return read(url)
        } catch {
            return nil
        }
    }

    /// Puts the desktop back as it was in `snapshot` (the current arrangement is saved first, so
    /// the restore can itself be undone).
    static func restore(_ snapshot: Snapshot) {
        guard let data = try? Data(contentsOf: snapshot.url),
              let file = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let layout = file["layout"] as? Data else { return }
        take(automatic: false)
        defaults.set(layout, forKey: "desktopLayout")
        AppDelegate.shared.reloadDesktopLayout()
    }

    static func delete(_ snapshot: Snapshot) {
        try? FileManager.default.trashItem(at: snapshot.url, resultingItemURL: nil)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Keeps the newest `keep` automatic snapshots.
    private static func prune() {
        for old in all.filter(\.automatic).dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
    }

    // MARK: Schedule (a timer every half hour; nothing else runs)

    private static var timer: Timer?

    static func startSchedule() {
        timer?.invalidate()
        let check = Timer(timeInterval: 30 * 60, repeats: true) { _ in MainActor.assumeIsolated { takeIfDue() } }
        check.tolerance = 5 * 60
        RunLoop.main.add(check, forMode: .common)
        timer = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { takeIfDue() }
    }

    static func takeIfDue() {
        guard intervalHours > 0, Settings.replaceFinder else { return }
        let last = defaults.object(forKey: "desktopSnapshotLast") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Double(intervalHours) * 3600 else { return }
        take(automatic: true)
    }

    static func describe(_ snapshot: Snapshot) -> String {
        let date = DateFormatter()
        date.locale = Localization.locale
        date.dateStyle = .medium
        date.timeStyle = .short
        return date.string(from: snapshot.date)
    }
}

/// Settings ▸ Ограды ▸ «Снимки…»: the list of desktop snapshots — restore, delete, take one now.
final class DesktopSnapshotsSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let restoreButton = NSButton(title: L("Восстановить"), target: nil, action: nil)
    private let deleteButton = NSButton(title: L("Удалить"), target: nil, action: nil)
    private var snapshots: [DesktopSnapshots.Snapshot] = []
    private let observers = Observers()

    override func loadView() {
        for (id, title, width) in [("date", L("Когда"), 220.0), ("kind", L("Как"), 120.0), ("contents", L("Что"), 170.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(restore(_:))
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let heading = NSTextField(labelWithString: L("Снимки рабочего стола"))
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = SettingsForm.wideHint(L("Где стоят значки (в оградах и вне их), ограды и порталы. «Восстановить» возвращает рабочий стол к снимку; текущая расстановка перед этим сохраняется отдельным снимком."))
        let take = NSButton(title: L("Сделать снимок"), target: self, action: #selector(takeNow(_:)))
        let reveal = NSButton(title: L("Показать файлы"), target: self, action: #selector(revealFolder(_:)))
        let done = NSButton(title: L("Готово"), target: self, action: #selector(close(_:)))
        done.keyEquivalent = "\r"
        restoreButton.target = self
        restoreButton.action = #selector(restore(_:))
        deleteButton.target = self
        deleteButton.action = #selector(remove(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [take, reveal, spacer, deleteButton, restoreButton, done])
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, hint, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 260),
            scroll.widthAnchor.constraint(equalToConstant: 540),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        view = stack
        observers.add(DesktopSnapshots.didChange) { [weak self] in self?.reload() }
        reload()
    }

    private func reload() {
        snapshots = DesktopSnapshots.all
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        restoreButton.isEnabled = snapshots.indices.contains(table.selectedRow)
        deleteButton.isEnabled = restoreButton.isEnabled
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshots.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let snapshot = snapshots[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = DesktopSnapshots.describe(snapshot)
        case "kind": text = snapshot.automatic ? L("Автоматически") : L("Вручную")
        default:
            text = "\(snapshot.icons) \(plural(snapshot.icons, L("значок"), L("значка"), L("значков"))), \(snapshot.fences) \(plural(snapshot.fences, L("ограда"), L("ограды"), L("оград")))"
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue != "date" { label.textColor = .secondaryLabelColor }
        return label
    }

    @objc private func takeNow(_ sender: Any?) { DesktopSnapshots.take(automatic: false) }

    @objc private func restore(_ sender: Any?) {
        guard snapshots.indices.contains(table.selectedRow) else { return }
        DesktopSnapshots.restore(snapshots[table.selectedRow])
    }

    @objc private func remove(_ sender: Any?) {
        guard snapshots.indices.contains(table.selectedRow) else { return }
        DesktopSnapshots.delete(snapshots[table.selectedRow])
    }

    @objc private func revealFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: DesktopSnapshots.folder, withIntermediateDirectories: true)
        AppDelegate.shared.openWindow(at: DesktopSnapshots.folder)
    }

    @objc private func close(_ sender: Any?) {
        guard let window = view.window, let parent = window.sheetParent else { return view.window?.close() ?? () }
        parent.endSheet(window)
    }
}
