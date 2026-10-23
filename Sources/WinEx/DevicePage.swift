import AppKit

/// An iPhone's or iPad's page, in place of Finder's (which only Apple's apps may show): its
/// picture, name, model, storage and battery, then «Основные», «Файлы» (apps' documents) and
/// «Фото» (the camera roll's folders). Backups, updates and syncing stay Finder's: «Открыть в Finder».
@MainActor
final class DevicePageView: NSView {
    /// The status bar's text.
    var onStatus: ((String) -> Void)?
    /// Another tab shows: the window's view buttons are on for «Файлы» only.
    var onTabShown: (() -> Void)?
    /// Going to another place of the device (a folder entered, back to its page).
    var onOpen: ((URL) -> Void)?

    private(set) var udid: String?
    private let picture = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let storageBar = NSLevelIndicator()
    private let storageLabel = NSTextField(labelWithString: "")
    private let finderButton = NSButton(title: L("Открыть в Finder"), target: nil, action: nil)
    private let tabs = NSSegmentedControl(labels: [L("Основные"), L("Файлы"), L("Фото")], trackingMode: .selectOne, target: nil, action: nil)
    /// The folder shown in flat mode (see `Location.device`).
    private var path = ""
    private static let flatKey = "deviceFilesFlat"
    private let general = NSStackView()
    private let generalScroll = NSScrollView()
    private let files = DeviceFilesView()
    private let photos = DevicePhotosView()
    private var details: MobileDevices.Details?
    private var generation = 0
    private var shownTabs: Set<Int> = []
    private let observers = Observers()

    private static let tabKey = "devicePageTab"

    override init(frame: NSRect) {
        super.init(frame: frame)
        picture.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        modelLabel.textColor = .secondaryLabelColor
        storageLabel.textColor = .secondaryLabelColor
        storageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        storageBar.levelIndicatorStyle = .continuousCapacity
        storageBar.minValue = 0
        storageBar.maxValue = 1
        storageBar.warningValue = 0.9
        storageBar.criticalValue = 0.97
        finderButton.bezelStyle = .push
        finderButton.target = self
        finderButton.action = #selector(openInFinder(_:))
        finderButton.toolTip = L("Резервные копии, обновление ПО и синхронизация — в Finder")
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.selectedSegment = min(max(AppDefaults.store.integer(forKey: Self.tabKey), 0), 2)
        // «Файлы» as a tree (the window's table button) or as folders' icons (its icons button)
        files.setFlat(AppDefaults.store.bool(forKey: Self.flatKey))
        files.onEnter = { [weak self] place in
            guard let self, let udid else { return }
            onOpen?(Places.deviceURL(udid, path: place))
        }

        let titles = NSStackView(views: [nameLabel, modelLabel, storageBar, storageLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4
        titles.setCustomSpacing(10, after: modelLabel)
        let header = NSStackView(views: [picture, titles, NSView(), finderButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        general.orientation = .vertical
        general.alignment = .leading
        general.spacing = 8
        general.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
        let generalDocument = FlippedView()
        general.translatesAutoresizingMaskIntoConstraints = false
        generalDocument.addSubview(general)
        generalScroll.documentView = generalDocument
        generalScroll.drawsBackground = false
        generalScroll.hasVerticalScroller = true
        generalScroll.autohidesScrollers = true
        generalDocument.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, tabs, generalScroll, files, files.overlay, photos] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.widthAnchor.constraint(equalToConstant: 84),
            picture.heightAnchor.constraint(equalToConstant: 84),
            storageBar.widthAnchor.constraint(equalToConstant: 260),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            tabs.centerXAnchor.constraint(equalTo: centerXAnchor),

            generalDocument.topAnchor.constraint(equalTo: generalScroll.contentView.topAnchor),
            generalDocument.leadingAnchor.constraint(equalTo: generalScroll.contentView.leadingAnchor),
            generalDocument.trailingAnchor.constraint(equalTo: generalScroll.contentView.trailingAnchor),
            general.topAnchor.constraint(equalTo: generalDocument.topAnchor),
            general.leadingAnchor.constraint(equalTo: generalDocument.leadingAnchor),
            general.trailingAnchor.constraint(lessThanOrEqualTo: generalDocument.trailingAnchor),
            general.bottomAnchor.constraint(equalTo: generalDocument.bottomAnchor),
        ])
        for content in [generalScroll, files, files.overlay, photos] as [NSView] {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        files.onStatus = { [weak self] text in
            guard let self, !files.isHidden else { return }
            onStatus?(text)
        }
        photos.onStatus = { [weak self] text in
            guard let self, !photos.isHidden else { return }
            onStatus?(text)
        }
        // Renamed, gone to sleep, back: the header follows
        observers.add(MobileDevices.didChange) { [weak self] in self?.updateHeader() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows a device (a folder of its files: `path`, see `Location.device`); its details and lists
    /// are read in the background.
    func show(_ udid: String, path: String = "") {
        let changed = udid != self.udid
        self.udid = udid
        self.path = path
        // A folder's place (back, a path step): «Файлы» as folders
        if !path.isEmpty {
            tabs.selectedSegment = 1
            if !files.flat { files.setFlat(true) }
        }
        generation += 1
        if changed {
            details = Self.detailsSeen[udid]
            shownTabs = []
        }
        updateHeader()
        readDetails()
        showTab()
        if device?.remembered == true { MobileDevices.shared.learnNamesFromFinder() }
    }

    private var device: MobileDevices.Device? { udid.flatMap { MobileDevices.shared.device($0) } }

    private func updateHeader() {
        guard let device else {
            nameLabel.stringValue = L("Устройство не подключено")
            modelLabel.stringValue = L("Подключите iPhone или iPad кабелем либо разблокируйте его рядом с Mac.")
            picture.image = NSImage(systemSymbolName: "iphone.slash", accessibilityDescription: nil)
            showStorage(nil)
            finderButton.isEnabled = false
            return
        }
        picture.image = device.image
        nameLabel.stringValue = device.name
        var model = [device.modelName, (device.deviceClass == "iPad" ? "iPadOS " : "iOS ") + device.version]
        if let battery = details?.battery {
            model.append(L("Заряд %@ %", String(battery)) + (details?.charging == true ? " ⚡︎" : ""))
        }
        model.append(device.away ? L("не на связи") : device.wifi ? "Wi‑Fi" : L("кабель"))
        modelLabel.stringValue = model.joined(separator: " · ")
        finderButton.isEnabled = true
        if let capacity = details?.capacity, capacity > 0, let free = details?.free {
            showStorage(Double(capacity - free) / Double(capacity))
            storageLabel.stringValue = L("Свободно %@ из %@", ByteCountFormatter.string(fromByteCount: free, countStyle: .file),
                                         ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))
        } else {
            showStorage(nil)
        }
        if tabs.selectedSegment == 0 { fillGeneral() }
    }

    /// What each device said last (shown at once when its page opens again, then read anew).
    private static var detailsSeen: [String: MobileDevices.Details] = [:]

    /// The bar keeps its place while there's nothing to show yet (the page doesn't jump when it comes).
    private func showStorage(_ used: Double?) {
        storageBar.alphaValue = used == nil ? 0 : 1
        storageBar.doubleValue = used ?? 0
        if used == nil { storageLabel.stringValue = " " }
    }

    private func readDetails() {
        guard let udid else { return }
        let generation = generation
        MobileDevices.queue.async {
            let result = Result { try MobileDevices.details(udid) }
            DispatchQueue.main.async {
                guard self.generation == generation else { return }
                switch result {
                case .success(let details):
                    self.details = details
                    Self.detailsSeen[udid] = details
                case .failure(let error):
                    MobileDevices.log.info("details: \(String(describing: error), privacy: .public)")
                }
                self.updateHeader()
            }
        }
    }

    @objc private func tabChanged(_ sender: Any?) {
        AppDefaults.store.set(tabs.selectedSegment, forKey: Self.tabKey)
        showTab()
    }

    /// «Файлы» shown as folders' icons (true) or as the tree.
    var filesAsIcons: Bool { files.flat }

    /// The window's view buttons act on «Файлы» only (they're off on the other tabs).
    var showsFiles: Bool { tabs.selectedSegment == 1 }

    /// The window's view buttons: icons → folders one at a time, table → the tree.
    func setFilesAsIcons(_ flat: Bool) {
        guard showsFiles else { return }
        AppDefaults.store.set(flat, forKey: Self.flatKey)
        guard flat != files.flat else { return }
        files.setFlat(flat)
        // The tree has no folder of its own: back to the device's page
        if !flat, !path.isEmpty, let udid { return onOpen?(Places.deviceURL(udid)) ?? () }
        showTab()
    }

    private func showTab() {
        let tab = tabs.selectedSegment
        generalScroll.isHidden = tab != 0
        files.isHidden = tab != 1
        files.overlay.isHidden = tab != 1
        photos.isHidden = tab != 2
        onTabShown?()
        guard let udid else { return }
        switch tab {
        case 1:
            if files.flat {
                files.open(udid, path: path)
            } else if shownTabs.insert(tab).inserted {
                // Read once per visit of the device (again with «Обновить»)
                files.show(udid)
            } else {
                files.reloadStatus()
            }
            window?.makeFirstResponder(files.focusView)
        case 2:
            if shownTabs.insert(tab).inserted { photos.show(udid) } else { photos.reloadStatus() }
            window?.makeFirstResponder(photos.focusView)
        default:
            fillGeneral()
        }
    }

    private func fillGeneral() {
        general.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let device else { return }
        var rows: [(String, String)] = [
            (L("Модель"), device.modelName),
            (L("Версия ПО"), (device.deviceClass == "iPad" ? "iPadOS " : "iOS ") + device.version + (details?.build.map { " (\($0))" } ?? "")),
        ]
        if let capacity = details?.capacity { rows.append((L("Ёмкость"), ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))) }
        if let free = details?.free { rows.append((L("Свободно"), ByteCountFormatter.string(fromByteCount: free, countStyle: .file))) }
        if let battery = details?.battery {
            rows.append((L("Аккумулятор"), "\(battery) %" + (details?.charging == true ? " — " + L("заряжается") : "")))
        }
        if let phone = details?.phoneNumber, !phone.isEmpty { rows.append((L("Номер телефона"), phone)) }
        if let serial = details?.serial { rows.append((L("Серийный номер"), serial)) }
        rows.append(("UDID", device.udid))
        rows.append((L("Подключение"), device.away ? L("не на связи") : device.wifi ? "Wi‑Fi" : L("кабель")))
        let grid = NSGridView(views: rows.map { title, value in
            let name = NSTextField(labelWithString: title + ":")
            name.textColor = .secondaryLabelColor
            name.alignment = .right
            let text = NSTextField(labelWithString: value)
            text.isSelectable = true
            return [name, text]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        general.addArrangedSubview(grid)
        let note = NSTextField(wrappingLabelWithString: L("Резервное копирование, обновление ПО, синхронизация музыки, фильмов и фото — в Finder."))
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 420
        general.addArrangedSubview(note)
        general.setCustomSpacing(18, after: grid)
        onStatus?(device.modelName)
    }

    @objc private func openInFinder(_ sender: Any?) {
        guard let device else { return }
        MobileDevices.openInFinder(device)
    }
}

extension DeviceFilesView {
    /// The status bar again, coming back to the tab.
    func reloadStatus() { onStatus?(statusText) }
}

// MARK: - Scenarios

extension DevicePageView {
    var debugHeader: String { "\(nameLabel.stringValue) | \(modelLabel.stringValue) | \(storageLabel.stringValue) | finder \(finderButton.isEnabled)" }
    func debugSetFlat(_ on: Bool) { setFilesAsIcons(on) }
    func debugSelectTab(_ tab: Int) {
        tabs.selectedSegment = tab
        showTab()
    }
    var debugList: DeviceFilesView? { tabs.selectedSegment == 1 ? files : nil }
    var debugPhotos: DevicePhotosView { photos }
}

extension DeviceFilesView {
    /// The rows shown, children indented.
    var debugRows: [String] {
        if flat { return ["(icons)"] + shown.map { "\($0.name)\($0.isDirectory ? "/" : "")" } }
        guard let outline = documentView as? NSOutlineView else { return [] }
        return (0..<outline.numberOfRows).map { row in
            let item = outline.item(atRow: row)
            let text = (item as? Node).map { "\($0.name)\($0.isDirectory ? "/" : "") \($0.size.map(String.init) ?? "")" } ?? "…"
            return String(repeating: "  ", count: outline.level(forRow: row)) + text
        }
    }
    var debugMessage: String { messageLabel.isHidden ? "" : messageLabel.stringValue }
    func debugExpand(_ name: String) {
        guard let outline = documentView as? NSOutlineView else { return }
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node, node.name == name { outline.expandItem(node) }
        }
    }
}
