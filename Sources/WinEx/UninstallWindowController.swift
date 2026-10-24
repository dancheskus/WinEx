import AppKit

/// «Удалить приложение…»: the app and what it left in the Libraries (settings, caches, data, saved
/// windows, login agents), each with a checkbox and its size, all moved to the Trash at once (one
/// ⌘Z puts them back). Also offered right after an app is put in the Trash some other way — when it
/// left files behind.
final class UninstallWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [UninstallWindowController] = []

    private struct Row {
        let url: URL
        /// nil: the app itself (always moved, in «Удалить приложение»).
        let kind: AppUninstall.Kind?
        let byName: Bool
        let needsAdmin: Bool
        var checked: Bool
        var size: Int64?
    }

    private let app: AppUninstall.App
    /// The app is in the Trash already (put there with Delete): only its files are offered.
    private let appTrashed: Bool
    /// …where it was → where it is: its files join that ⌘Z step.
    private var trashedApp: [URL: URL]?
    private var rows: [Row] = []
    private var otherCopies: [URL] = []
    private var searching = true
    private var working = false

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let removeButton = NSButton(title: L("Удалить"), target: nil, action: nil)

    // MARK: Entry points

    /// «Удалить приложение…» in a file's menu, when it's an app that can be removed.
    static func menuItem(for urls: [URL]) -> NSMenuItem? {
        guard urls.count == 1, let url = urls.first, AppUninstall.app(at: url) != nil else { return nil }
        let item = NSMenuItem(title: L("Удалить приложение…"), action: #selector(MenuTarget.uninstall(_:)), keyEquivalent: "")
        item.target = MenuTarget.shared
        item.representedObject = url
        item.image = MenuStyle.symbol("xmark.app")
        return item
    }

    private final class MenuTarget: NSObject {
        static let shared = MenuTarget()
        @objc func uninstall(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL { UninstallWindowController.uninstall(url) }
        }
    }

    static func uninstall(_ url: URL) {
        guard let app = AppUninstall.app(at: url) else { return }
        if let shown = open.first(where: { $0.app.url == app.url && !$0.appTrashed }) {
            shown.showWindow(nil)
            return
        }
        present(UninstallWindowController(app: app, appTrashed: false))
    }

    /// The apps just put in the Trash (where they were → where they are now): their files are
    /// looked for, and offered if there are any and no other copy of the app stays.
    static func offerLeftovers(of apps: [AppUninstall.App], trashed: [URL: URL]) {
        for app in apps {
            guard let now = trashed[app.url] else { continue }
            let moved = AppUninstall.App(url: now, name: app.name, names: app.names, bundleID: app.bundleID, teamID: app.teamID)
            let installed = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: app.bundleID)
            DispatchQueue.global(qos: .userInitiated).async {
                let found = search(moved, installed: installed)
                guard !found.leftovers.isEmpty, found.copies.isEmpty else { return }
                DispatchQueue.main.async {
                    let controller = UninstallWindowController(app: moved, appTrashed: true)
                    controller.trashedApp = [app.url: now]
                    controller.show(found)
                    present(controller)
                }
            }
        }
    }

    private static func present(_ controller: UninstallWindowController) {
        open.append(controller)
        let mouse = NSEvent.mouseLocation
        let screen = NSApp.keyWindow?.screen ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let window = controller.window, let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2 + 60))
        }
        NSApp.activate()
        controller.showWindow(nil)
        #if DEBUG
        debugLast = controller
        #endif
    }

    // MARK: Search

    private struct Found: Sendable {
        var leftovers: [AppUninstall.Leftover]
        var copies: [URL]
    }

    nonisolated private static func search(_ app: AppUninstall.App, installed: [URL]) -> Found {
        let copies = AppUninstall.otherCopies(of: app, launchServices: installed)
        let others = AppUninstall.otherApps(than: app)
        var leftovers = AppUninstall.leftovers(of: app, userLibrary: userLibrary, systemLibrary: systemLibrary,
                                               otherBundleIDs: others.ids, otherNames: others.names, otherTeamApps: others.sameTeam)
        // (Never the app itself, nor anything inside it)
        let own = app.url.standardizedFileURL.path + "/"
        leftovers.removeAll { ($0.url.standardizedFileURL.path + "/").hasPrefix(own) }
        return Found(leftovers: leftovers, copies: copies)
    }

    #if DEBUG
    /// Scenarios look in a made-up Library.
    nonisolated(unsafe) static var debugLibraries: (user: URL, system: URL?)?
    #endif
    nonisolated private static var userLibrary: URL {
        #if DEBUG
        if let debugLibraries { return debugLibraries.user }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
    }
    nonisolated private static var systemLibrary: URL? {
        #if DEBUG
        if let debugLibraries { return debugLibraries.system }
        #endif
        return URL(fileURLWithPath: "/Library", isDirectory: true)
    }

    // MARK: Window

    private init(app: AppUninstall.App, appTrashed: Bool) {
        self.app = app
        self.appTrashed = appTrashed
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = appTrashed ? L("Файлы приложения «%@»", app.name) : L("Удалить «%@»", app.name)
        window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        build()
        if !appTrashed {
            rows = [Row(url: app.url, kind: nil, byName: false, needsAdmin: false, checked: true)]
            let installed = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: app.bundleID)
            DispatchQueue.global(qos: .userInitiated).async { [app] in
                let found = Self.search(app, installed: installed)
                DispatchQueue.main.async { [weak self] in self?.show(found) }
            }
        }
        measure()
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func show(_ found: Found) {
        searching = false
        otherCopies = found.copies
        // Another copy stays: the files are its too, nothing is checked
        let shared = !found.copies.isEmpty
        rows += found.leftovers.map {
            Row(url: $0.url, kind: $0.kind, byName: $0.byName, needsAdmin: $0.needsAdmin, checked: !shared && !$0.byName)
        }
        table.reloadData()
        measure()
        update()
    }

    /// Each row's size, worked out in the background.
    private func measure() {
        for (index, row) in rows.enumerated() where row.size == nil {
            let url = row.url
            DispatchQueue.global(qos: .utility).async {
                let bytes = Self.allocatedSize(of: url)
                DispatchQueue.main.async { [weak self] in
                    guard let self, rows.indices.contains(index), rows[index].url == url else { return }
                    rows[index].size = bytes
                    table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                    update()
                }
            }
        }
    }

    nonisolated private static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return Int64(values?.totalFileAllocatedSize ?? 0) }
        var bytes: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            bytes += Int64((try? item.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return bytes
    }

    private func build() {
        guard let content = window?.contentView else { return }
        iconView.image = NSWorkspace.shared.icon(forFile: app.url.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 48).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 48).isActive = true
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        titleLabel.stringValue = appTrashed ? L("«%@» перемещено в Корзину. Удалить и его файлы?", app.name)
                                            : L("Удалить «%@» вместе с его файлами?", app.name)
        infoLabel.stringValue = L("Это настройки, кэш и данные приложения. Отмеченное будет перемещено в Корзину — оттуда его можно вернуть.")
        infoLabel.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [titleLabel, infoLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4
        for label in [titleLabel, infoLabel] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let header = NSStackView(views: [iconView, texts])
        header.alignment = .top
        header.spacing = 12

        // The name and the place share what's left
        for (id, title, width) in [("check", "", 24.0), ("name", L("Имя"), 260.0), ("kind", L("Что это"), 170.0),
                                   ("place", L("Где"), 200.0), ("size", L("Размер"), 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            if ["check", "kind", "size"].contains(id) {
                column.minWidth = width
                column.maxWidth = width
                column.resizingMask = []
            } else {
                column.minWidth = 120
                column.resizingMask = .autoresizingMask
            }
            if id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.rowHeight = 24
        table.allowsEmptySelection = true
        table.target = self
        table.doubleAction = #selector(revealRow(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        status.maximumNumberOfLines = 5
        status.preferredMaxLayoutWidth = 0
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.alignment = .top
        statusRow.spacing = 6

        let cancel = NSButton(title: appTrashed ? L("Оставить") : L("Отменить"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        removeButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, removeButton])
        buttons.spacing = 8

        for view in [header, scroll, statusRow, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            statusRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            statusRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    /// The app's bundle: where it is, and where it was before Delete put it in the Trash.
    private var bundlePaths: [String] {
        ([app.url] + (trashedApp?.keys.map { $0 } ?? [])).map(AppUninstall.realPath)
    }

    /// The app and everything it started from inside its bundle — helpers with IDs of their own,
    /// like a menu bar item kept as a login item («Usage Menu.app» in Usage.app).
    private var runningCopies: [NSRunningApplication] {
        let paths = bundlePaths
        return NSWorkspace.shared.runningApplications.filter { running in
            guard running.processIdentifier != getpid() else { return false }
            if let url = running.bundleURL ?? running.executableURL,
               AppUninstall.isInside(AppUninstall.realPath(url), paths) { return true }
            // Its own ID, from wherever it runs — unless another copy stays (only this one closes)
            return otherCopies.isEmpty && running.bundleIdentifier == app.bundleID
        }
    }

    private func update() {
        let checked = rows.filter(\.checked)
        let bytes = checked.compactMap(\.size).reduce(0, +)
        var lines: [String] = []
        if searching {
            lines.append(L("Поиск файлов приложения…"))
        } else {
            let files = rows.filter { $0.kind != nil }
            if files.isEmpty {
                lines.append(L("Других файлов приложения не найдено."))
            }
            let count = checked.count
            lines.append(L("Отмечено: %@ из %@ · %@", count, rows.count, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        if let copy = otherCopies.first {
            lines.append(L("Есть ещё одна копия «%@» (%@) — эти файлы общие с ней, поэтому они не отмечены.",
                           app.name, (copy.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
        }
        if rows.contains(where: { $0.byName }) {
            lines.append(L("Найденное только по названию не отмечено — проверьте, что это файлы «%@» (двойной щелчок покажет в папке).", app.name))
        }
        if !runningCopies.isEmpty {
            lines.append(L("«%@» сейчас открыто — WinEx закроет его перед удалением.", app.name))
        }
        if checked.contains(where: \.needsAdmin) {
            lines.append(L("Для части файлов понадобится пароль администратора."))
        }
        status.stringValue = lines.joined(separator: "\n")
        status.textColor = .secondaryLabelColor
        if searching { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        removeButton.isEnabled = !working && !checked.isEmpty && !(appTrashed && searching)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let id = column.identifier
        if id.rawValue == "check" {
            let box = (tableView.makeView(withIdentifier: id, owner: nil) as? NSButton) ?? {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
                box.identifier = id
                return box
            }()
            box.state = item.checked ? .on : .off
            box.tag = row
            // The app itself goes in any case
            box.isEnabled = item.kind != nil && !working
            return box
        }
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            var constraints = [
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ]
            if id.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                constraints += [
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ]
            } else {
                constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4))
            }
            if id.rawValue == "size" { field.alignment = .right }
            NSLayoutConstraint.activate(constraints)
            return cell
        }()
        guard let field = cell.textField else { return cell }
        field.textColor = id.rawValue == "name" ? .labelColor : .secondaryLabelColor
        switch id.rawValue {
        case "name":
            field.stringValue = item.url.lastPathComponent
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
        case "kind":
            field.stringValue = kindTitle(item)
        case "place":
            field.stringValue = (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        default:
            field.stringValue = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…"
        }
        field.lineBreakMode = .byTruncatingMiddle
        cell.toolTip = item.url.path
        return cell
    }

    private func kindTitle(_ row: Row) -> String {
        let title: String
        switch row.kind {
        case nil: title = L("Приложение")
        case .settings: title = L("Настройки")
        case .data: title = L("Данные")
        case .cache: title = L("Кэш")
        case .logs: title = L("Журналы")
        case .windows: title = L("Открытые окна")
        case .autostart: title = L("Автозапуск")
        case .service: title = L("Служба")
        }
        return row.byName ? L("%@ (по названию)", title) : title
    }

    @objc private func toggle(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), rows[sender.tag].kind != nil else { return }
        rows[sender.tag].checked = sender.state == .on
        update()
    }

    @objc private func revealRow(_ sender: Any?) {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        AppDelegate.shared.reveal(rows[row].url)
    }

    // MARK: Removing

    @objc private func cancel(_ sender: Any?) { window?.close() }

    @objc private func remove(_ sender: Any?) {
        update()
        guard removeButton.isEnabled else { return }
        working = true
        update()
        table.reloadData()
        quitApp { [weak self] quit in
            guard let self else { return }
            guard quit else {
                working = false
                table.reloadData()
                update()
                return
            }
            moveToTrash()
        }
    }

    /// Asks the app to quit (and waits); if it won't, offers to force it. `done(false)`: it stays open.
    private func quitApp(_ done: @escaping (Bool) -> Void) {
        let running = runningCopies
        guard !running.isEmpty else {
            stopHelpers()
            return done(true)
        }
        status.stringValue = L("Закрываю «%@»…", app.name)
        running.forEach { $0.terminate() }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                waited += 0.25
                let left = running.filter { !$0.isTerminated }
                guard let self, !left.isEmpty else {
                    timer.invalidate()
                    self?.stopHelpers()
                    return done(true)
                }
                guard waited >= 8 else { return }
                timer.invalidate()
                guard let window = self.window else { return done(false) }
                let alert = NSAlert()
                alert.messageText = L("«%@» не закрывается", self.app.name)
                alert.informativeText = L("Возможно, в нём есть несохранённые изменения. Закройте его сами или завершите принудительно.")
                alert.addButton(withTitle: L("Завершить принудительно"))
                alert.addButton(withTitle: L("Отменить"))
                alert.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn else { return done(false) }
                    left.forEach { $0.forceTerminate() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.stopHelpers()
                        done(true)
                    }
                }
            }
        }
    }

    /// Whatever still runs from inside the bundle once the app has quit (tools, agents) is stopped.
    private func stopHelpers() {
        for pid in AppUninstall.processes(inside: bundlePaths) { kill(pid, SIGTERM) }
    }

    private func moveToTrash() {
        let checked = rows.filter(\.checked)
        // Login agents stop first, so they don't start again
        let uid = getuid()
        for row in checked where row.kind == .autostart && !row.needsAdmin && row.url.pathExtension == "plist" {
            Self.run("/bin/launchctl", ["bootout", "gui/\(uid)", row.url.path])
        }
        // Everything at once: what's root's (an App Store app, files in /Library) after one password
        let urls = checked.map(\.url)
        let appURL = app.url
        let appWasTrashed = trashedApp?.values.first
        FileOperations.start(.trash, urls, joiningUndo: trashedApp) { [weak self] result in
            // «Вернуть» on the app in the Trash brings these back too
            if let app = appWasTrashed ?? result.done.first(where: { $0.from == appURL })?.to {
                Places.rememberTogether(app: app, files: result.done.filter { $0.from != appURL }.map(\.to))
            }
            let left = urls.filter { url in !result.done.contains { $0.from == url } }
            guard !left.isEmpty, !result.cancelled, let self, let window else { return self?.window?.close() ?? () }
            let alert = NSAlert()
            alert.messageText = L("Часть файлов осталась на месте")
            alert.informativeText = L("Не удалось убрать: %@.", left.map(\.lastPathComponent).joined(separator: ", "))
            alert.beginSheetModal(for: window) { _ in self.window?.close() }
        }
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    #if DEBUG
    nonisolated(unsafe) static weak var debugLast: UninstallWindowController?
    var debugRows: [String] {
        rows.map { "\($0.checked ? "[x]" : "[ ]") \($0.url.lastPathComponent) — \(kindTitle($0))\($0.needsAdmin ? " (admin)" : "")" }
    }
    var debugSearching: Bool { searching }
    var debugState: String { "\(status.stringValue.replacingOccurrences(of: "\n", with: " | ")); button \(removeButton.isEnabled ? "on" : "off")" }
    func debugToggle(_ name: String) {
        guard let index = rows.firstIndex(where: { $0.url.lastPathComponent == name }), rows[index].kind != nil else { return }
        rows[index].checked.toggle()
        table.reloadData()
        update()
    }
    func debugRemove() { remove(nil) }
    var debugTrashedApp: URL? { trashedApp?.values.first }
    #endif
}
