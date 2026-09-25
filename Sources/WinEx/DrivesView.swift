import AppKit

/// "Этот Mac" — every drive with a bar of how full it is, like Explorer's "This PC".
/// Capacities are read in the background (network volumes can be slow) whenever the view is shown
/// and when drives come and go; nothing runs in between.
@MainActor
final class DrivesView: NSScrollView {
    struct Drive {
        let url: URL
        var name: String
        var icon: NSImage
        var total: Int64?
        var free: Int64?
        var ejectable: Bool
        var network: Bool
    }

    var onOpen: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onProperties: ((URL) -> Void)?

    private let content = FlippedView()
    private var drives: [Drive] = []
    private var tiles: [DriveTile] = []
    private var headers: [NSTextField] = []
    private(set) var selected: Int? { didSet { tiles.enumerated().forEach { $0.element.isSelected = $0.offset == selected } } }
    private let observers = Observers()
    private var generation = 0

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        documentView = content
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.add(name, center: NSWorkspace.shared.notificationCenter) { [weak self] in
                guard let self, !self.isHidden else { return }
                self.reload()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var driveCount: Int { drives.count }

    /// Lists the drives now; sizes follow from a background read.
    func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey]
        drives = (fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Drive(url: url, name: values?.volumeLocalizedName ?? url.lastPathComponent,
                         icon: NSWorkspace.shared.icon(forFile: url.path), total: nil, free: nil,
                         ejectable: values?.volumeIsEjectable == true || values?.volumeIsRemovable == true || values?.volumeIsLocal == false,
                         network: values?.volumeIsLocal == false)
        }
        rebuildTiles()
        generation += 1
        let token = generation
        let urls = drives.map(\.url)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Free space as Finder counts it: with purgeable space (caches, iCloud copies). Network
            // volumes report 0 for that figure — then the plain free space
            let sizes = urls.map { url -> (Int64?, Int64?) in
                let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                                               .volumeAvailableCapacityKey])
                let important = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
                let free = important ?? values?.volumeAvailableCapacity.map(Int64.init)
                return (values?.volumeTotalCapacity.map(Int64.init), free)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation else { return }
                    for (i, size) in sizes.enumerated() where self.drives.indices.contains(i) {
                        self.drives[i].total = size.0
                        self.drives[i].free = size.1
                        self.tiles[i].drive = self.drives[i]
                    }
                }
            }
        }
    }

    private func rebuildTiles() {
        (tiles as [NSView] + headers).forEach { $0.removeFromSuperview() }
        tiles = drives.map { drive in
            let tile = DriveTile(drive: drive)
            content.addSubview(tile)
            return tile
        }
        headers = []
        for title in ["Устройства и диски", "Сетевые расположения"] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 15)
            label.textColor = .controlAccentColor
            content.addSubview(label)
            headers.append(label)
        }
        selected = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(contentSize.width, 300)
        let tileSize = NSSize(width: 300, height: 66)
        let columns = max(1, Int((width - 24) / (tileSize.width + 12)))
        var y: CGFloat = 12
        for (n, network) in [false, true].enumerated() {
            let group = drives.indices.filter { drives[$0].network == network }
            headers[safe: n]?.isHidden = group.isEmpty
            guard !group.isEmpty else { continue }
            headers[safe: n]?.frame = NSRect(x: 16, y: y, width: width - 32, height: 20)
            y += 30
            for (position, index) in group.enumerated() {
                let column = position % columns, row = position / columns
                tiles[index].frame = NSRect(x: 16 + CGFloat(column) * (tileSize.width + 12),
                                            y: y + CGFloat(row) * (tileSize.height + 8), width: tileSize.width, height: tileSize.height)
            }
            y += CGFloat((group.count + columns - 1) / columns) * (tileSize.height + 8) + 12
        }
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(y, contentSize.height))
    }

    // MARK: Mouse and keyboard

    override var acceptsFirstResponder: Bool { true }

    private func index(at event: NSEvent) -> Int? {
        let point = content.convert(event.locationInWindow, from: nil)
        return tiles.firstIndex { $0.frame.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selected = index(at: event)
        if event.clickCount == 2, let selected { onOpen?(drives[selected].url) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: if let selected { onOpen?(drives[selected].url) }       // Return
        case 123, 126: selected = max(0, (selected ?? 1) - 1)                 // ← ↑
        case 124, 125: selected = min(drives.count - 1, (selected ?? -1) + 1) // → ↓
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: event) else { return nil }
        selected = index
        let drive = drives[index]
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = menu.addItem(withTitle: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let handler = MenuAction(action)
            item.target = handler
            item.representedObject = handler
        }
        add("Открыть") { [weak self] in self?.onOpen?(drive.url) }
        add("Открыть в новой вкладке") { [weak self] in self?.onOpenInNewTab?(drive.url) }
        if drive.ejectable {
            menu.addItem(.separator())
            add("Извлечь «\(drive.name)»") { SystemDesktop.eject(drive.url) }
        }
        menu.addItem(.separator())
        add("Свойства") { [weak self] in self?.onProperties?(drive.url) }
        return menu
    }
}

/// One drive: icon, name, the fill bar (red when nearly full), "X свободно из Y".
private final class DriveTile: NSView {
    var drive: DrivesView.Drive { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }

    init(drive: DrivesView.Drive) {
        self.drive = drive
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        drive.icon.draw(in: NSRect(x: 6, y: 9, width: 48, height: 48), from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)
        let left: CGFloat = 64, width = bounds.width - left - 10
        drive.name.draw(with: NSRect(x: left, y: 6, width: width, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
        guard let total = drive.total, total > 0, let free = drive.free else {
            let text = drive.total == nil && drive.free == nil ? "…" : ""
            text.draw(at: NSPoint(x: left, y: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let used = min(1, max(0, Double(total - free) / Double(total)))
        let bar = NSRect(x: left, y: 27, width: width, height: 12)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        (used > 0.9 ? NSColor.systemRed : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(6, bar.width * used), height: bar.height), xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).stroke()
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        "\(format(free)) свободно из \(format(total))".draw(at: NSPoint(x: left, y: 44), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
}

/// A big centered message over the file list ("Эта папка пуста", no access to the Trash…) with an
/// optional button. Clicks outside the button fall through to the list (context menu, rubber band).
final class EmptyStateView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 380
        button.target = self
        button.action = #selector(pressed)
        let stack = NSStackView(views: [title, detail, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 60),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, detail: String = "", button: String? = nil, action: (() -> Void)? = nil) {
        title.stringValue = text
        self.detail.stringValue = detail
        self.detail.isHidden = detail.isEmpty
        self.button.title = button ?? ""
        self.button.isHidden = button == nil
        self.action = action
        isHidden = false
    }

    @objc private func pressed() { action?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !button.isHidden, let hit = super.hitTest(point), hit === button || hit.isDescendant(of: button) else { return nil }
        return hit
    }
}

/// Runs a closure from a menu item.
final class MenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
