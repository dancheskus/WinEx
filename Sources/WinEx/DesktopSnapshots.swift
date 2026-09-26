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
        /// What the desktop looked like (every monitor, wallpaper, icons, zones).
        let preview: NSImage?

        static func == (a: Snapshot, b: Snapshot) -> Bool { a.url == b.url }
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
                        fences: file["fences"] as? Int ?? 0, icons: file["icons"] as? Int ?? 0,
                        preview: (file["preview"] as? Data).flatMap(NSImage.init(data:)))
    }

    /// The desktop's arrangement as stored by WinEx now.
    private static var currentLayout: Data? { defaults.data(forKey: "desktopLayout") }

    /// Saves the current arrangement. Automatic ones are skipped when nothing changed since the last.
    @discardableResult
    static func take(automatic: Bool, preview: NSImage? = nil) -> Snapshot? {
        guard let layout = currentLayout else { return nil }
        if automatic, let last = all.first, let data = try? Data(contentsOf: last.url),
           let file = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           file["layout"] as? Data == layout {
            defaults.set(Date(), forKey: "desktopSnapshotLast")
            return nil
        }
        let counts = (try? JSONSerialization.jsonObject(with: layout) as? [String: Any]) ?? [:]
        var file: [String: Any] = [
            "date": Date(), "automatic": automatic, "layout": layout, "version": Updater.shared.currentVersion,
            "fences": (counts["fences"] as? [Any])?.count ?? 0, "icons": (counts["positions"] as? [String: Any])?.count ?? 0,
        ]
        // The picture: a JPEG of the desktop as it is now
        if let image = preview ?? AppDelegate.shared.desktopPreview(), let tiff = image.tiffRepresentation,
           let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
            file["preview"] = jpeg
        }
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

/// Settings ▸ Снимки: automatic snapshots (how often), take one now, and every snapshot as a card
/// with its picture — restore or delete it.
final class SnapshotsSettingsView: NSView {
    private let cards = NSStackView()
    private let empty = SettingsForm.wideHint(L("Снимков пока нет. Они появятся автоматически или по кнопке «Сделать снимок»."))
    private let observers = Observers()

    init() {
        super.init(frame: .zero)
        let interval = NSPopUpButton()
        for option in DesktopSnapshots.intervals {
            interval.addItem(withTitle: option.title)
            interval.lastItem?.tag = option.hours
        }
        interval.selectItem(withTag: DesktopSnapshots.intervalHours)
        interval.target = self
        interval.action = #selector(intervalChanged(_:))
        let take = NSButton(title: L("Сделать снимок"), target: self, action: #selector(takeNow(_:)))
        take.bezelColor = .controlAccentColor
        let reveal = NSButton(title: L("Показать файлы"), target: self, action: #selector(revealFolder(_:)))
        let label = NSTextField(labelWithString: L("Автоматически:"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [label, interval, spacer, reveal, take])
        header.spacing = 8
        let hint = SettingsForm.wideHint(L("Снимок — вся расстановка рабочего стола: значки в зонах и вне их, зоны и порталы, на всех мониторах. «Восстановить» возвращает её; текущая перед этим сохраняется отдельным снимком. Хранятся 30 последних автоматических снимков, сделанные вручную — пока их не удалить."))

        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = 12
        let document = FlippedView()
        cards.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(cards)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cards.topAnchor.constraint(equalTo: document.topAnchor),
            cards.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            cards.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let stack = NSStackView(views: [header, hint, empty, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            widthAnchor.constraint(equalToConstant: SettingsForm.width),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 470),
        ])
        observers.add(DesktopSnapshots.didChange) { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func reload() {
        cards.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = DesktopSnapshots.all
        empty.isHidden = !all.isEmpty
        for snapshot in all {
            let card = SnapshotCard(snapshot)
            cards.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        }
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) { DesktopSnapshots.intervalHours = sender.selectedTag() }
    @objc private func takeNow(_ sender: Any?) { DesktopSnapshots.take(automatic: false) }

    @objc private func revealFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: DesktopSnapshots.folder, withIntermediateDirectories: true)
        AppDelegate.shared.openWindow(at: DesktopSnapshots.folder)
    }
}

/// One snapshot: its picture, when, how, what — and «Восстановить» / «Удалить».
private final class SnapshotCard: NSView {
    private let snapshot: DesktopSnapshots.Snapshot

    init(_ snapshot: DesktopSnapshots.Snapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        let picture = NSImageView()
        picture.wantsLayer = true
        if let preview = snapshot.preview {
            picture.image = preview
            picture.imageScaling = .scaleProportionallyUpOrDown
        } else {
            // Older snapshots have no picture: a small symbol on a dim plate
            picture.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 36, weight: .light))
            picture.imageScaling = .scaleNone
            picture.contentTintColor = .tertiaryLabelColor
            picture.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        }
        picture.layer?.cornerRadius = 8
        picture.layer?.masksToBounds = true
        let date = NSTextField(labelWithString: DesktopSnapshots.describe(snapshot))
        date.font = .systemFont(ofSize: 14, weight: .semibold)
        let kind = NSTextField(labelWithString: snapshot.automatic ? L("Автоматически") : L("Вручную"))
        kind.textColor = .secondaryLabelColor
        let contents = NSTextField(labelWithString:
            "\(snapshot.icons) \(plural(snapshot.icons, L("значок"), L("значка"), L("значков"))), \(snapshot.fences) \(plural(snapshot.fences, L("зона"), L("зоны"), L("зон")))")
        contents.textColor = .secondaryLabelColor
        let restore = NSButton(title: L("Восстановить"), target: self, action: #selector(restore(_:)))
        let delete = NSButton(title: L("Удалить"), target: self, action: #selector(remove(_:)))
        let buttons = NSStackView(views: [restore, delete])
        buttons.spacing = 8
        let info = NSStackView(views: [date, kind, contents, buttons])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 6
        info.setCustomSpacing(14, after: contents)
        let row = NSStackView(views: [picture, info])
        row.spacing = 16
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let ratio = snapshot.preview.map { $0.size.height / max($0.size.width, 1) } ?? 0.56
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            picture.widthAnchor.constraint(equalToConstant: 380),
            picture.heightAnchor.constraint(equalToConstant: min(380 * ratio, 260)),
        ])
        toolTip = snapshot.url.lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor }

    @objc private func restore(_ sender: Any?) { DesktopSnapshots.restore(snapshot) }
    @objc private func remove(_ sender: Any?) { DesktopSnapshots.delete(snapshot) }
}
