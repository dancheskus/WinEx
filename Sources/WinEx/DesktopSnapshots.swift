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
        let files = all.compactMap { snapshot -> [String: Any]? in
            guard let data = try? Data(contentsOf: snapshot.url) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }
        let same = files.filter { $0["layout"] as? Data == layout }
        // Nothing new since the last one: no automatic snapshot
        if automatic && files.first.map({ $0["layout"] as? Data == layout }) == true {
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
        } else if let earlier = same.lazy.compactMap({ $0["preview"] as? Data }).first {
            // WinEx isn't drawing the desktop now: the picture of the same arrangement taken earlier
            file["preview"] = earlier
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

    /// Puts the desktop back as it was in `snapshot`; with `saveCurrent`, the current arrangement
    /// is kept as a snapshot first (the settings ask).
    static func restore(_ snapshot: Snapshot, saveCurrent: Bool) {
        guard let data = try? Data(contentsOf: snapshot.url),
              let file = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let layout = file["layout"] as? Data else { return }
        if saveCurrent { take(automatic: false) }
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

/// The lower part of Settings ▸ Зоны: how often snapshots are taken, "take one now", and every
/// snapshot as a tile with its picture in a sideways-scrolling strip (newest first).
final class SnapshotsSection: NSView {
    private let strip = NSStackView()
    private let scroll = SidewaysScrollView()
    private let empty = SettingsForm.wideHint(L("Снимков пока нет. Они появятся автоматически или по кнопке «Сделать снимок»."))
    private let observers = Observers()

    init() {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: L("Снимки рабочего стола"))
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let interval = NSPopUpButton()
        for option in DesktopSnapshots.intervals {
            interval.addItem(withTitle: option.title)
            interval.lastItem?.tag = option.hours
        }
        interval.selectItem(withTag: DesktopSnapshots.intervalHours)
        interval.target = self
        interval.action = #selector(intervalChanged(_:))
        interval.controlSize = .small
        interval.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let label = NSTextField(labelWithString: L("Автоматически:"))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let reveal = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage(),
                              target: self, action: #selector(revealFolder(_:)))
        reveal.controlSize = .small
        reveal.toolTip = L("Показать файлы")
        let take = NSButton(title: L("Сделать снимок"), target: self, action: #selector(takeNow(_:)))
        take.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
        take.imagePosition = .imageLeading
        take.controlSize = .small
        take.bezelColor = .controlAccentColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer, label, interval, reveal, take])
        header.spacing = 8
        let hint = SettingsForm.wideHint(L("Снимок хранит, где лежат значки, зоны и порталы на всех мониторах. Перед восстановлением WinEx спросит, сохранить ли текущую расстановку."))

        strip.orientation = .horizontal
        strip.alignment = .top
        strip.spacing = 12
        strip.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        let document = FlippedView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(strip)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: document.topAnchor),
            strip.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])

        let stack = NSStackView(views: [header, hint, empty, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: SnapshotTile.height + 10),
        ])
        observers.add(DesktopSnapshots.didChange) { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The section got taller or shorter (the first snapshot, the last one gone).
    var onResize: (() -> Void)?

    private func reload() {
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = DesktopSnapshots.all
        let wasEmpty = scroll.isHidden
        empty.isHidden = !all.isEmpty
        scroll.isHidden = all.isEmpty
        all.forEach { strip.addArrangedSubview(SnapshotTile($0)) }
        if wasEmpty != all.isEmpty { onResize?() }
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) { DesktopSnapshots.intervalHours = sender.selectedTag() }
    @objc private func takeNow(_ sender: Any?) {
        DesktopSnapshots.take(automatic: false)
        scroll.contentView.scroll(to: .zero)
    }

    @objc private func revealFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: DesktopSnapshots.folder, withIntermediateDirectories: true)
        AppDelegate.shared.openWindow(at: DesktopSnapshots.folder)
    }
}

/// A strip that scrolls sideways with an ordinary mouse wheel too.
private final class SidewaysScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let maxX = max(document.frame.width - contentView.bounds.width, 0)
        let x = min(max(contentView.bounds.origin.x - step, 0), maxX)
        contentView.scroll(to: NSPoint(x: x, y: contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}

/// One snapshot: its picture (a click shows it bigger), when, what — «Восстановить» and a bin.
private final class SnapshotTile: NSView {
    static let width: CGFloat = 200
    static let pictureHeight: CGFloat = 124
    static let height: CGFloat = 214
    private let snapshot: DesktopSnapshots.Snapshot
    private let picture = NSImageView()

    init(_ snapshot: DesktopSnapshots.Snapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true
        picture.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        if let preview = snapshot.preview {
            picture.image = preview
            picture.imageScaling = .scaleProportionallyUpOrDown
            picture.toolTip = L("Показать крупнее")
        } else {
            // Older snapshots have no picture: a small symbol on a dim plate
            picture.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 26, weight: .light))
            picture.imageScaling = .scaleNone
            picture.contentTintColor = .tertiaryLabelColor
        }
        let date = NSTextField(labelWithString: DesktopSnapshots.describe(snapshot))
        date.font = .systemFont(ofSize: 12, weight: .semibold)
        let contents = NSTextField(labelWithString:
            "\(snapshot.automatic ? L("Авто") : L("Вручную")) · \(snapshot.icons) \(plural(snapshot.icons, L("значок"), L("значка"), L("значков"))), \(snapshot.fences) \(plural(snapshot.fences, L("зона"), L("зоны"), L("зон")))")
        contents.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        contents.textColor = .secondaryLabelColor
        contents.lineBreakMode = .byTruncatingTail
        let restore = NSButton(title: L("Восстановить"), target: self, action: #selector(restore(_:)))
        restore.controlSize = .small
        let delete = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: L("Удалить")) ?? NSImage(),
                              target: self, action: #selector(remove(_:)))
        delete.controlSize = .small
        delete.toolTip = L("Удалить")
        let buttons = NSStackView(views: [restore, delete])
        buttons.spacing = 6
        let stack = NSStackView(views: [picture, date, contents, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(8, after: picture)
        stack.setCustomSpacing(8, after: contents)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            picture.widthAnchor.constraint(equalTo: stack.widthAnchor),
            picture.heightAnchor.constraint(equalToConstant: Self.pictureHeight),
            contents.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        toolTip = snapshot.url.lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor }

    private var pictureRect: NSRect { picture.convert(picture.bounds, to: self) }

    override func mouseDown(with event: NSEvent) {
        guard let preview = snapshot.preview,
              pictureRect.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        // The picture, big, in a popover
        let size = NSSize(width: 640, height: (640 * preview.size.height / max(preview.size.width, 1)).rounded())
        let big = NSImageView(frame: NSRect(origin: .zero, size: size))
        big.image = preview
        big.imageScaling = .scaleProportionallyUpOrDown
        let controller = NSViewController()
        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size.width + 20, height: size.height + 20)))
        big.frame.origin = NSPoint(x: 10, y: 10)
        container.addSubview(big)
        controller.view = container
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: picture.bounds, of: picture, preferredEdge: .maxY)
    }

    override func resetCursorRects() {
        if snapshot.preview != nil { addCursorRect(pictureRect, cursor: .pointingHand) }
    }

    /// Asks first: keep the current arrangement as a snapshot, or just restore.
    @objc private func restore(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L("Восстановить расстановку от %@?", DesktopSnapshots.describe(snapshot))
        alert.informativeText = L("Значки, зоны и порталы встанут так, как в этом снимке. Текущую расстановку можно сперва сохранить снимком, чтобы к ней вернуться.")
        alert.addButton(withTitle: L("Сохранить и восстановить"))
        alert.addButton(withTitle: L("Восстановить без сохранения"))
        alert.addButton(withTitle: L("Отменить"))
        let snapshot = snapshot
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: DesktopSnapshots.restore(snapshot, saveCurrent: true)
            case .alertSecondButtonReturn: DesktopSnapshots.restore(snapshot, saveCurrent: false)
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
    }
    @objc private func remove(_ sender: Any?) { DesktopSnapshots.delete(snapshot) }
}
