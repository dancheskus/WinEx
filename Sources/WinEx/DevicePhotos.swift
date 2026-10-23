import AppKit
import Quartz
import UniformTypeIdentifiers

/// The «Фото» tab of a device's page: the photos and videos kept on the device, as a grid of the
/// device's own thumbnails (PhotoData/Thumbnails/V2), newest first. They're exported to a folder,
/// dragged out, or opened (a copy). What iCloud keeps only in the cloud isn't on the device to copy.
@MainActor
final class DevicePhotosView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    struct Photo: Sendable {
        enum Kind: Sendable { case photo, live, video, screenshot }

        /// /DCIM/113APPLE/IMG_3147.HEIC
        let path: String
        /// A Live Photo's video (IMG_3147.MOV beside IMG_3147.HEIC): exported with the picture.
        var companion: String?
        var name: String { (path as NSString).lastPathComponent }
        var isVideo: Bool { kind == .video }
        /// HEIC, JPEG, PNG, MOV…
        var format: String {
            let ext = (name as NSString).pathExtension.uppercased()
            return ext == "JPG" ? "JPEG" : ext
        }
        /// What the device's library says it is; without the library, a guess by the name.
        var library: DevicePhotoLibrary.Asset?
        /// Without the library, screenshots are the PNGs (the camera itself takes HEIC or JPEG).
        var kind: Kind {
            if companion != nil { return .live }
            if let library { return library.isVideo ? .video : library.isScreenshot ? .screenshot : .photo }
            let type = UTType(filenameExtension: (name as NSString).pathExtension)
            if type?.conforms(to: .movie) == true { return .video }
            return format == "PNG" ? .screenshot : .photo
        }
        /// The device's thumbnail of it.
        var thumbnailPath: String { "/PhotoData/Thumbnails/V2" + path + "/5005.JPG" }
    }

    var onStatus: ((String) -> Void)?
    private var store: DeviceFileStore?
    /// Everything on the device, newest first.
    private var all: [Photo] = []
    /// What the filters let through: the grid's items.
    private var photos: [Photo] = []

    /// «Все / Фото / Live Photo / Видео / Снимки экрана».
    private enum Filter: Int, CaseIterable {
        case all, photos, live, videos, screenshots

        var title: String {
            switch self {
            case .all: L("Все")
            case .photos: L("Фото")
            case .live: "Live Photo"
            case .videos: L("Видео")
            case .screenshots: L("Снимки экрана")
            }
        }

        func admits(_ photo: Photo) -> Bool {
            switch self {
            case .all: true
            case .photos: photo.kind != .video
            case .live: photo.kind == .live
            case .videos: photo.kind == .video
            case .screenshots: photo.kind == .screenshot
            }
        }
    }
    private var filter = Filter.all
    /// A format chosen in «Формат» (nil: any).
    private var format: String?
    private let filterControl = NSSegmentedControl()
    private lazy var filterWidth = filterControl.widthAnchor.constraint(equalToConstant: 400)
    private let formatButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let selectAllButton = NSButton(title: L("Выбрать все"), target: nil, action: nil)
    private let selectNoneButton = NSButton(title: L("Снять выбор"), target: nil, action: nil)
    private var thumbnails: [String: NSImage] = [:]
    /// Thumbnails asked for by cells that showed, latest last; one at a time is fetched.
    private var wanted: [Photo] = []
    private var fetching = false
    private var generation = 0
    private var busy: String?
    private var message: String?

    private let grid = DevicePhotoGrid()
    private let preview = DevicePreview()
    private let scroll = NSScrollView()
    private let exportButton = NSButton(title: L("Экспортировать…"), target: nil, action: nil)
    private let noteLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    var focusView: NSView { grid }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 118, height: 118)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 16, bottom: 16, right: 16)
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.clear]
        grid.dataSource = self
        grid.delegate = self
        grid.register(DevicePhotoItem.self, forItemWithIdentifier: DevicePhotoItem.identifier)
        grid.onOpen = { [weak self] in self?.openSelected() }
        grid.onOpenItem = { [weak self] index in
            guard let self, index < photos.count else { return }
            open([photos[index]])
        }
        grid.onSpace = { [weak self] in
            guard let self, let store else { return }
            preview.keyView = grid
            preview.toggle(previewItems, store: store)
        }
        grid.preview = preview
        grid.onSelectionChange = { [weak self] in self?.selectionChanged() }
        preview.onLoading = { [weak self] text in
            guard let self else { return }
            setBusy(text)
            if text != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        exportButton.target = self
        exportButton.action = #selector(export(_:))
        exportButton.toolTip = L("Скопировать выбранные снимки (или все, если ничего не выбрано) в папку на Mac")
        filterControl.segmentCount = Filter.allCases.count
        filterControl.trackingMode = .selectOne
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        filterControl.selectedSegment = 0
        formatButton.target = self
        formatButton.action = #selector(formatChanged(_:))
        formatButton.toolTip = L("Только снимки этого формата")
        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllPhotos(_:))
        selectAllButton.toolTip = L("Выбрать все показанные (⌘A)")
        selectNoneButton.target = self
        selectNoneButton.action = #selector(selectNoPhotos(_:))
        updateFilterControls()
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.lineBreakMode = .byTruncatingTail
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3

        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        for view in [filterControl, formatButton, selectAllButton, selectNoneButton, noteLabel, exportButton, scroll, messageLabel, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            filterControl.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            filterControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            filterWidth,
            formatButton.centerYAnchor.constraint(equalTo: filterControl.centerYAnchor),
            formatButton.leadingAnchor.constraint(equalTo: filterControl.trailingAnchor, constant: 10),
            formatButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            // Second row: the note on the left, selecting and exporting on the right
            exportButton.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 8),
            exportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            selectNoneButton.centerYAnchor.constraint(equalTo: exportButton.centerYAnchor),
            selectNoneButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -8),
            selectAllButton.centerYAnchor.constraint(equalTo: exportButton.centerYAnchor),
            selectAllButton.trailingAnchor.constraint(equalTo: selectNoneButton.leadingAnchor, constant: -4),
            noteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            noteLabel.centerYAnchor.constraint(equalTo: exportButton.centerYAnchor),
            noteLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectAllButton.leadingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: exportButton.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -60),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Loading

    func show(_ udid: String) {
        let store = DeviceFileStore.store(udid)
        if self.store !== store { thumbnails = [:] }
        wanted = []
        self.store = store
        generation += 1
        let generation = generation
        all = []
        photos = []
        grid.reloadData()
        updateFilterControls()
        setMessage(L("Загрузка…"))
        spinner.startAnimation(nil)
        noteLabel.stringValue = ""
        exportButton.isEnabled = false
        store.queue.async {
            let result: Result<[Photo], Error> = Result {
                try store.with(.media) { afc in
                    // Only what the library shows: DCIM keeps the recently deleted and hidden ones too
                    let library = DevicePhotoLibrary.shown(afc, udid: udid)
                    func asset(_ folder: String, _ name: String) -> DevicePhotoLibrary.Asset? {
                        library?["/DCIM/\(folder)/\(name)".uppercased()]
                    }
                    var photos: [Photo] = []
                    for folder in try afc.list("/DCIM") where !folder.hasPrefix(".") {
                        let names = try afc.list("/DCIM/" + folder).filter { !$0.hasPrefix(".") }
                        // A Live Photo is a picture and a video of the same name: one item
                        let videos = Set(names.filter { ($0 as NSString).pathExtension.uppercased() == "MOV" }
                            .map { ($0 as NSString).deletingPathExtension.uppercased() })
                        var paired: Set<String> = []
                        for name in names {
                            let ext = (name as NSString).pathExtension.uppercased()
                            let base = (name as NSString).deletingPathExtension.uppercased()
                            if ["HEIC", "JPG", "JPEG"].contains(ext), videos.contains(base),
                               let video = names.first(where: { ($0 as NSString).deletingPathExtension.uppercased() == base
                                   && ($0 as NSString).pathExtension.uppercased() == "MOV" }) {
                                paired.insert(base)
                                guard library == nil || asset(folder, name) != nil else { continue }
                                photos.append(Photo(path: "/DCIM/\(folder)/\(name)", companion: "/DCIM/\(folder)/\(video)",
                                                    library: asset(folder, name)))
                            }
                        }
                        for name in names {
                            let ext = (name as NSString).pathExtension.uppercased()
                            // Edits' sidecar files (.AAE) aren't pictures; paired pictures and videos are in already
                            guard ext != "AAE", !(paired.contains((name as NSString).deletingPathExtension.uppercased())
                                && ["HEIC", "JPG", "JPEG", "MOV"].contains(ext)) else { continue }
                            guard library == nil || asset(folder, name) != nil else { continue }
                            photos.append(Photo(path: "/DCIM/\(folder)/\(name)", library: asset(folder, name)))
                        }
                    }
                    return photos
                }
            }
            DispatchQueue.main.async {
                guard self.generation == generation else { return }
                self.spinner.stopAnimation(nil)
                switch result {
                case .success(let photos):
                    // Folders and numbers grow with time: newest first
                    self.all = photos.sorted { $0.path.localizedStandardCompare($1.path) == .orderedDescending }
                    self.applyFilter()
                    self.setMessage(photos.isEmpty ? L("На устройстве нет снимков. Если включена «Оптимизация хранилища», они хранятся в iCloud.") : nil)
                    self.noteLabel.stringValue = photos.isEmpty ? "" : L("Снимки, хранящиеся только в iCloud, здесь не видны.")
                    self.exportButton.isEnabled = !photos.isEmpty
                case .failure(let error):
                    self.setMessage(L("Не удалось прочитать устройство: %@", String(describing: error)))
                }
            }
        }
    }

    // MARK: Filters and selection

    /// The grid shows what the filters let through; the selection starts over.
    private func applyFilter() {
        photos = all.filter { filter.admits($0) && (format == nil || $0.format == format) }
        grid.selectionIndexPaths = []
        grid.reloadData()
        updateFilterControls()
        if !all.isEmpty { setMessage(photos.isEmpty ? L("Нет снимков с такими условиями.") : nil) }
        selectionChanged()
    }

    /// Counts in the filter's segments, the formats there are in «Формат».
    private func updateFilterControls() {
        for item in Filter.allCases {
            let count = all.filter { item.admits($0) }.count
            let label = all.isEmpty ? item.title : "\(item.title) \(count)"
            filterControl.setLabel(label, forSegment: item.rawValue)
            filterControl.setEnabled(item == .all || count > 0 || all.isEmpty, forSegment: item.rawValue)
            // Each segment as wide as its label with the count (automatic widths stay as first laid out)
            let font = filterControl.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            filterControl.setWidth(ceil((label as NSString).size(withAttributes: [.font: font]).width) + 20, forSegment: item.rawValue)
        }
        filterWidth.constant = (0..<filterControl.segmentCount).reduce(CGFloat(8)) { $0 + filterControl.width(forSegment: $1) + 2 }
        filterControl.selectedSegment = filter.rawValue
        let formats = Dictionary(grouping: all.filter { filter.admits($0) }, by: \.format).mapValues(\.count)
        formatButton.removeAllItems()
        formatButton.addItem(withTitle: L("Любой формат"))
        for (name, count) in formats.sorted(by: { $0.key < $1.key }) {
            formatButton.addItem(withTitle: "\(name) — \(count)")
            formatButton.lastItem?.representedObject = name
        }
        if let format, let item = formatButton.itemArray.first(where: { $0.representedObject as? String == format }) {
            formatButton.select(item)
        } else {
            formatButton.selectItem(at: 0)
        }
        let selected = grid.selectionIndexPaths.count
        selectAllButton.isEnabled = !photos.isEmpty && selected < photos.count
        selectNoneButton.isEnabled = selected > 0
        exportButton.title = selected > 0 ? L("Экспортировать (%@)…", String(selected)) : L("Экспортировать…")
    }

    @objc private func filterChanged(_ sender: Any?) {
        filter = Filter(rawValue: filterControl.selectedSegment) ?? .all
        // A format the new filter doesn't have would show nothing
        if let format, !all.contains(where: { filter.admits($0) && $0.format == format }) { self.format = nil }
        applyFilter()
    }

    @objc private func formatChanged(_ sender: Any?) {
        format = formatButton.selectedItem?.representedObject as? String
        applyFilter()
    }

    @objc private func selectAllPhotos(_ sender: Any?) {
        grid.selectionIndexPaths = Set(photos.indices.map { IndexPath(item: $0, section: 0) })
        selectionChanged()
    }

    @objc private func selectNoPhotos(_ sender: Any?) {
        grid.selectionIndexPaths = []
        selectionChanged()
    }

    private func selectionChanged() {
        updateStatus()
        updateFilterControls()
        preview.selectionChanged(previewItems)
    }

    private func setMessage(_ text: String?) {
        message = text
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
    }

    var statusText: String {
        if let busy { return busy }
        let selected = grid.selectionIndexPaths.count
        let count = photos.count
        let shown = "\(count) \(plural(count, L("снимок"), L("снимка"), L("снимков")))"
        return selected > 0 ? L("Выбрано %@ из %@", String(selected), shown) : shown
    }

    func reloadStatus() { onStatus?(statusText) }
    private func updateStatus() { onStatus?(statusText) }

    private func setBusy(_ text: String?) {
        busy = text
        updateStatus()
    }

    /// Asks the device for a thumbnail the first time its cell shows.
    private func loadThumbnail(_ photo: Photo) {
        guard thumbnails[photo.path] == nil, !wanted.contains(where: { $0.path == photo.path }) else { return }
        wanted.append(photo)
        // After the grid's layout: the cell asking counts as shown then
        if !fetching { DispatchQueue.main.async { self.fetchNextThumbnail() } }
    }

    /// One thumbnail at a time on the device's queue: what else is asked of the device (Space,
    /// export) waits for one, not for a whole screen of them. The ones last shown come first; the
    /// ones scrolled past are left (their cells ask again when they show).
    private func fetchNextThumbnail() {
        guard !fetching, let store else { return }
        let visible = Set(grid.indexPathsForVisibleItems().map(\.item).filter { $0 < photos.count }.map { photos[$0].path })
        wanted.removeAll { !visible.contains($0.path) || thumbnails[$0.path] != nil }
        guard let photo = wanted.popLast() else { return }
        fetching = true
        let generation = generation
        store.queue.async {
            let data = try? store.with(.media) { try $0.data(photo.thumbnailPath) }
            let image = data.flatMap(DevicePhotoItem.squareThumbnail)
            DispatchQueue.main.async {
                self.fetching = false
                if self.generation == generation, let image {
                    self.thumbnails[photo.path] = image
                    if let index = self.photos.firstIndex(where: { $0.path == photo.path }),
                       let item = self.grid.item(at: IndexPath(item: index, section: 0)) as? DevicePhotoItem {
                        item.show(image)
                    }
                }
                self.fetchNextThumbnail()
            }
        }
    }

    // MARK: Grid

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { photos.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: DevicePhotoItem.identifier, for: indexPath)
        guard let photoItem = item as? DevicePhotoItem, indexPath.item < photos.count else { return item }
        let photo = photos[indexPath.item]
        photoItem.configure(name: photo.name, kind: photo.kind, image: thumbnails[photo.path])
        loadThumbnail(photo)
        return photoItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

    private var previewItems: [DevicePreview.Item] {
        selectedPhotos.map { DevicePreview.Item(root: .media, path: $0.path, size: nil) }
    }

    private var selectedPhotos: [Photo] {
        grid.selectionIndexPaths.sorted().compactMap { $0.item < photos.count ? photos[$0.item] : nil }
    }

    // MARK: Export and open

    @objc private func export(_ sender: Any?) {
        let chosen = selectedPhotos.isEmpty ? photos : selectedPhotos
        guard !chosen.isEmpty, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Экспортировать")
        panel.message = L("Куда скопировать снимки (%@)?", String(chosen.count))
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.copy(chosen, to: folder) { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    private func openSelected() { open(selectedPhotos) }

    private func open(_ chosen: [Photo]) {
        guard !chosen.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WinEx Devices/\(UUID().uuidString)")
        copy(chosen, to: folder) { urls in urls.forEach { NSWorkspace.shared.open($0) } }
    }

    /// Copies originals into a Mac folder (names made unique), then `done` with the copies.
    private func copy(_ chosen: [Photo], to folder: URL, done: @escaping ([URL]) -> Void) {
        guard let store else { return }
        setBusy(L("Копирование с устройства…"))
        store.queue.async {
            var copied: [URL] = []
            var failure: Error?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, photo) in chosen.enumerated() {
                    let target = Self.unique(folder.appendingPathComponent(photo.name))
                    try store.download(.media, photo.path, isDirectory: false, to: target) { _ in true }
                    copied.append(target)
                    // A Live Photo's video beside its picture, under the same name
                    if let companion = photo.companion {
                        let video = target.deletingPathExtension().appendingPathExtension((companion as NSString).pathExtension)
                        try store.download(.media, companion, isDirectory: false, to: Self.unique(video)) { _ in true }
                    }
                    DispatchQueue.main.async {
                        self.setBusy(L("Копирование с устройства… %@ из %@", String(index + 1), String(chosen.count)))
                    }
                }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                self.setBusy(nil)
                if let failure, !(failure is CancellationError) {
                    let alert = NSAlert()
                    alert.messageText = L("Не удалось выполнить действие на устройстве")
                    alert.informativeText = String(describing: failure)
                    if let window = self.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                }
                if !copied.isEmpty { done(copied) }
            }
        }
    }

    nonisolated private static func unique(_ url: URL) -> URL {
        var candidate = url
        var number = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

/// Photos chosen as in Photos on the iPhone: a click marks a photo or unmarks it (the others
/// stay), pressing and moving marks every photo from the first to the one under the pointer (or
/// unmarks them, when the first was marked), scrolling at the edges; ⇧-click marks the range from
/// the last one clicked, ⌘A all of them. Double-click and ↩ open, Space shows Quick Look.
private final class DevicePhotoGrid: NSCollectionView, DevicePreviewHost {
    var onOpen: (() -> Void)?
    var onOpenItem: ((Int) -> Void)?
    var onSpace: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    weak var preview: DevicePreview?
    /// Where a ⇧-click's range starts.
    private var anchor: Int?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewAccepts() }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { previewBegin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { previewEnd(panel) }

    private func index(at event: NSEvent) -> Int? {
        indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let start = index(at: event) else { return }
        // The second click of a double-click: that photo, marked, is opened
        if event.clickCount == 2 {
            selectItems(at: [IndexPath(item: start, section: 0)], scrollPosition: [])
            onSelectionChange?()
            return onOpenItem?(start) ?? ()
        }
        if event.modifierFlags.contains(.shift), let anchor {
            let range = min(anchor, start)...max(anchor, start)
            selectItems(at: Set(range.map { IndexPath(item: $0, section: 0) }), scrollPosition: [])
            return onSelectionChange?() ?? ()
        }
        let before = selectionIndexPaths
        let marking = !before.contains(IndexPath(item: start, section: 0))
        func paint(to end: Int) {
            let range = Set((min(start, end)...max(start, end)).map { IndexPath(item: $0, section: 0) })
            selectionIndexPaths = marking ? before.union(range) : before.subtracting(range)
            onSelectionChange?()
        }
        paint(to: start)
        anchor = start
        // Following the pointer until the button is let go
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            autoscroll(with: next)
            if let end = index(at: next) { paint(to: end) }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectionIndexPaths = Set((0..<numberOfItems(inSection: 0)).map { IndexPath(item: $0, section: 0) })
            return onSelectionChange?() ?? ()
        }
        switch event.keyCode {
        case 36, 76: onOpen?()
        case 49: onSpace?()
        default: super.keyDown(with: event)
        }
    }
}

/// A square thumbnail, a ▶ on videos, an accent frame when selected.
private final class DevicePhotoItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("devicePhoto")
    /// The thumbnail as the layer's contents: nothing to draw as the grid is laid out again.
    private let picture = NSView()
    private let badge = NSImageView()
    private let check = NSImageView()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 6
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        picture.wantsLayer = true
        badge.contentTintColor = .white
        badge.shadow = Self.shadow
        check.shadow = Self.shadow
        for view in [picture, badge, check] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: root.topAnchor),
            picture.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            badge.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            check.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            check.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
        ])
        view = root
        updateCheck()
    }

    private static let shadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        return shadow
    }()

    func configure(name: String, kind: DevicePhotosView.Photo.Kind, image: NSImage?) {
        view.toolTip = name
        let symbol: NSImage? = switch kind {
        case .video: Self.videoBadge
        case .live: Self.liveBadge
        default: nil
        }
        if badge.image !== symbol { badge.image = symbol }
        badge.isHidden = symbol == nil
        show(image)
    }

    // Made once: a grid's new row makes many cells at a time (as a window is zoomed)
    private static func symbol(_ name: String, _ size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }
    private static let videoBadge = symbol("play.circle.fill", 18)
    private static let liveBadge = symbol("livephoto", 18)
    private static let checked = symbol("checkmark.circle.fill", 20)
    private static let unchecked = symbol("circle", 20)

    private func updateCheck() {
        check.image = isSelected ? Self.checked : Self.unchecked
        check.contentTintColor = isSelected ? .controlAccentColor : .white
    }

    /// The thumbnail (already square); a type icon until it comes.
    func show(_ image: NSImage?) {
        if let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            picture.layer?.contents = image
            picture.layer?.contentsGravity = .resizeAspectFill
        } else {
            picture.layer?.contents = Self.placeholder
            picture.layer?.contentsGravity = .resizeAspect
        }
    }

    private static let placeholder = NSWorkspace.shared.icon(for: .image)

    /// The device's thumbnail cropped to the middle square (like Photos' grid) and decoded once, at
    /// the cell's size on a Retina screen: the grid only puts a bitmap on screen, at any window size.
    /// Off the main thread.
    nonisolated static func squareThumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = min(image.width, image.height)
        guard side > 0, let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                                                width: side, height: side)) else { return nil }
        let pixels = min(side, 256)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let bitmap = context.makeImage() else { return nil }
        return NSImage(cgImage: bitmap, size: NSSize(width: pixels / 2, height: pixels / 2))
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            updateCheck()
        }
    }
}

// MARK: - Scenarios

extension DevicePhotosView {
    func debugQuickLookFirst() {
        guard !photos.isEmpty else { return }
        grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        grid.onSpace?()
    }
    var debugBusy: String { busy ?? "" }
    var debugFilters: String {
        let segments = (0..<filterControl.segmentCount).map { filterControl.label(forSegment: $0) ?? "" }
        return "\(segments), formats \(formatButton.itemTitles), shown \(photos.count), selected \(grid.selectionIndexPaths.count), export «\(exportButton.title)»"
    }
    func debugFilter(_ index: Int) {
        filterControl.selectedSegment = index
        filterChanged(nil)
    }
    func debugSelectAll() { selectAllPhotos(nil) }
    var debugGrid: NSView { grid }
    func debugCenter(_ index: Int) -> NSPoint {
        let frame = grid.frameForItem(at: index)
        return NSPoint(x: frame.midX, y: frame.midY)
    }
    var debugSelected: [Int] { grid.selectionIndexPaths.map(\.item).sorted() }
    var debugSummary: String { "\(photos.count) photos, \(thumbnails.count) thumbnails, message «\(message ?? "")», note «\(noteLabel.stringValue)»" }
}
