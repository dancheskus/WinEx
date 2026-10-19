import AppKit
import Quartz
import QuickLookThumbnailing

/// Finder's preview pane (⇧⌘P, «Панель предпросмотра» in the view menus): the selected file as a
/// whole-page Quick Look picture in a rounded frame (videos and sounds play there), its name and
/// size, kind, dates, tags and what `FileDetails` knows about it; the folder shown when nothing is
/// selected; a count for several.
final class PreviewPane: NSView {
    static let minimumWidth: CGFloat = 220
    static let maximumWidth: CGFloat = 560

    /// New windows open with the pane as it was left last (each window then has its own).
    static var isShownByDefault: Bool {
        get { AppDefaults.store.bool(forKey: "showPreviewPane") }
        set { AppDefaults.store.set(newValue, forKey: "showPreviewPane") }
    }

    /// What the user last dragged it to, for every window.
    static var width: CGFloat {
        get { CGFloat(AppDefaults.store.object(forKey: "previewPaneWidth") as? Double ?? 280) }
        set { AppDefaults.store.set(Double(newValue), forKey: "previewPaneWidth") }
    }

    /// «Открыть»: the file list opens the selection (folders in the window, files in their apps).
    var onOpen: (() -> Void)?

    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private lazy var preview: QLPreviewView? = {
        let view = QLPreviewView(frame: .zero, style: .normal)
        view?.autostarts = false
        view?.shouldCloseWithWindow = true
        return view
    }()
    private let iconView = NSImageView()
    /// Finder's frame around the preview: the page or picture fitted into it whole.
    private let previewBox = PreviewBox()
    private let thumbnailView = NSImageView()
    /// The thumbnail being made (a newer selection replaces it).
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    /// Text files are shown as text, as in Finder: wrapped, scrolled, selectable.
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    /// The file whose text is being read (a newer selection replaces it).
    private var textURL: URL?
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let kindLabel = NSTextField(wrappingLabelWithString: "")
    private let placeholder = NSTextField(labelWithString: L("Нет предпросмотра"))
    private let openButton = PreviewPane.actionButton(L("Открыть"), "arrow.up.forward.app")
    private let shareButton = PreviewPane.actionButton(L("Поделиться"), "square.and.arrow.up")
    private let infoButton = PreviewPane.actionButton(L("Свойства"), "info.circle")
    private var buttons: [NSButton] { [openButton, shareButton, infoButton].filter { !$0.isHidden } }
    /// «Информация»: a label and its value per row, a hairline between rows. The kind's details
    /// (`extra`: pages, camera, codecs…) only after «Показать ещё», as in Finder.
    private var lines: [(label: NSTextField, value: NSTextField, extra: Bool)] = []
    private var separators: [NSBox] = []
    private let infoHeading = PreviewPane.heading(L("Информация"))
    private let moreButton = NSButton(title: "", target: nil, action: nil)
    /// «Теги»: the file's tags, typed or picked like in Finder.
    private let tagsHeading = PreviewPane.heading(L("Теги"))
    private let tagStrip = TagStrip()
    /// A folder's size, added up in the background (stopped when something else is shown).
    private var sizeTask: Task<Void, Never>?
    /// The whole name, before it's shortened to two lines.
    private var fullName = ""

    /// «Показать ещё» is remembered for every pane, as in Finder.
    private static var showsMore: Bool {
        get { AppDefaults.store.bool(forKey: "previewPaneShowsMore") }
        set { AppDefaults.store.set(newValue, forKey: "previewPaneShowsMore") }
    }

    /// What's shown: the selection, or the folder (`isFolderShown`).
    private(set) var urls: [URL] = []
    private var isFolderShown = false
    private var detailsTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Over the content: a scroller taking room as the rows grow would change the width they're laid out for
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        iconView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        previewBox.addSubview(thumbnailView)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.scrollerStyle = .overlay
        textScroll.drawsBackground = false
        textScroll.isHidden = true
        previewBox.addSubview(textScroll)
        nameLabel.font = .systemFont(ofSize: 17, weight: .medium)
        nameLabel.isSelectable = true
        kindLabel.font = .systemFont(ofSize: 13)
        kindLabel.textColor = .secondaryLabelColor
        moreButton.isBordered = false
        moreButton.font = .systemFont(ofSize: 12)
        moreButton.contentTintColor = .linkColor
        moreButton.alignment = .right
        moreButton.target = self
        moreButton.action = #selector(toggleMore(_:))
        tagStrip.onAdd = { [weak self] tag in self?.changeTags { $0 + [tag] } }
        tagStrip.onRemove = { [weak self] tag in self?.changeTags { $0.filter { $0.name != tag.name } } }
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        openButton.target = self; openButton.action = #selector(openItems(_:))
        shareButton.target = self; shareButton.action = #selector(shareItems(_:))
        infoButton.target = self; infoButton.action = #selector(showProperties(_:))
        [previewBox, iconView, nameLabel, kindLabel, placeholder, openButton, shareButton, infoButton,
         infoHeading, moreButton, tagsHeading, tagStrip].forEach(document.addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private static func actionButton(_ title: String, _ symbol: String) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageAbove
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        return button
    }

    // MARK: - What's shown

    /// Shows `selection`, or `folder` when nothing is selected (nil: a place without files of its
    /// own, as «Этот Mac»). The same items again change nothing (the list reports often).
    func show(selection: [URL], folder: URL?) {
        let files = selection.filter(\.isFileURL)
        let folderShown = files.isEmpty
        let shown = folderShown ? [folder].compactMap { $0 }.filter(\.isFileURL) : files
        guard shown != urls || folderShown != isFolderShown else { return }
        urls = shown
        isFolderShown = folderShown
        reload()
    }

    /// Reads everything about what's shown again (a file changed, the pane was shown).
    func reload() {
        detailsTask?.cancel()
        detailsTask = nil
        sizeTask?.cancel()
        sizeTask = nil
        setLines([])
        let urls = urls
        placeholder.isHidden = !urls.isEmpty
        for view in [iconView, nameLabel, kindLabel, infoHeading] as [NSView] { view.isHidden = urls.isEmpty }
        // Tags of one item (as in Finder; several would mean merging different sets)
        tagsHeading.isHidden = urls.count != 1
        tagStrip.isHidden = urls.count != 1
        tagStrip.tags = urls.count == 1 ? FileTags.tags(of: urls[0]) : []
        openButton.isHidden = urls.isEmpty || isFolderShown
        shareButton.isHidden = urls.isEmpty
        infoButton.isHidden = urls.isEmpty
        guard let first = urls.first else {
            showPreview(of: nil)
            return needsLayout = true
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .localizedTypeDescriptionKey, .fileSizeKey,
                                         .creationDateKey, .contentModificationDateKey, .tagNamesKey, .ubiquitousItemDownloadingStatusKey]
        let values = try? first.resourceValues(forKeys: keys)
        let isFolder = values?.isDirectory == true
        if urls.count == 1 {
            fullName = first.displayName
            // Under the name, like Finder: «PDF-документ — 31 КБ» (a folder has no size of its own)
            let kind = values?.localizedTypeDescription ?? ""
            let size = isFolder ? nil : values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            kindLabel.stringValue = [kind, size].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            // A preview of files (not of folders, apps and other packages, nor of iCloud files not
            // on this Mac: previewing would download them)
            let previewable = !isFolder && values?.ubiquitousItemDownloadingStatus != .notDownloaded
            showPreview(of: previewable ? first : nil)
            var rows: [Row] = []
            if let created = values?.creationDate { rows.append((L("Создан"), Self.date(created), false)) }
            if let modified = values?.contentModificationDate { rows.append((L("Изменён"), Self.date(modified), false)) }
            setLines(rows)
            loadDetails(of: first, isFolder: isFolder && values?.isPackage != true)
            if isFolder { addUpSize(of: first, kind: kind) }
        } else {
            fullName = "\(urls.count) \(plural(urls.count, L("объект"), L("объекта"), L("объектов")))"
            let sizes = urls.map { try? $0.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey]) }
            let kinds = Set(sizes.compactMap { $0?.localizedTypeDescription })
            kindLabel.stringValue = kinds.count == 1 ? kinds.first ?? "" : L("Разные типы")
            showPreview(of: nil)
            let folders = sizes.filter { $0?.isDirectory == true }.count
            let bytes = sizes.compactMap { $0?.isDirectory == true ? nil : $0?.fileSize }.reduce(Int64(0)) { $0 + Int64($1) }
            var rows: [Row] = []
            if folders < urls.count { rows.append((L("Размер файлов"), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), false)) }
            if folders > 0 { rows.append((L("Папок"), "\(folders)", false)) }
            setLines(rows)
        }
        iconView.image = Self.icon(for: urls)
        needsLayout = true
    }

    /// `url` in the frame — the whole first page or picture, a player for videos and sounds —
    /// the icon otherwise (and until the picture is made).
    private func showPreview(of url: URL?) {
        if let request = thumbnailRequest { QLThumbnailGenerator.shared.cancel(request) }
        thumbnailRequest = nil
        thumbnailView.image = nil
        textURL = nil
        textScroll.isHidden = true
        textView.string = ""
        preview?.previewItem = nil
        preview?.removeFromSuperview()
        previewBox.isHidden = true
        iconView.isHidden = urls.isEmpty
        guard let url else { return }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if type?.conforms(to: .audiovisualContent) == true, let preview {
            previewBox.addSubview(preview)
            preview.previewItem = url as NSURL
            previewBox.isHidden = false
            iconView.isHidden = true
            return needsLayout = true
        }
        if type?.conforms(to: .plainText) == true {
            return showText(of: url)
        }
        // Made as large as the frame can get, so a wider pane doesn't need a new one
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.maximumWidth, height: Self.pictureHeight),
                                                   scale: window?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.thumbnailRequest === request else { return }
                self.thumbnailRequest = nil
                self.thumbnailView.image = image
                self.previewBox.isHidden = false
                self.iconView.isHidden = true
                self.needsLayout = true
            }
        }
    }

    /// The beginning of a text file (scripts, notes, source code, JSON…), read in the background.
    private func showText(of url: URL) {
        textURL = url
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { Self.beginning(of: url) }.value
            guard let self, self.textURL == url, let text else { return }
            self.textView.string = text
            self.textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            self.textView.textColor = .labelColor
            self.textView.scroll(.zero)
            self.textScroll.isHidden = false
            self.previewBox.isHidden = false
            self.iconView.isHidden = true
            self.needsLayout = true
        }
    }

    /// The first 200 KB as text (UTF-8, else what the file says, else Latin 1); nil for a file
    /// that isn't text after all.
    nonisolated private static func beginning(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: 200_000) else { return nil }
        if data.contains(0) { return nil }
        // A UTF-8 character cut at the end
        for _ in 0..<3 where String(data: data, encoding: .utf8) == nil && !data.isEmpty { data.removeLast() }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1251) ?? String(data: data, encoding: .isoLatin1)
    }

    /// The frame's height at most (it's as wide as the pane).
    private static let previewHeight: CGFloat = 340
    /// A page or picture's height at most: a portrait page gets the pane's whole width, as in Finder.
    private static let pictureHeight: CGFloat = 520

    /// One icon, or a few fanned out behind each other for several items.
    private static func icon(for urls: [URL]) -> NSImage? {
        let icons = urls.prefix(3).map { NSWorkspace.shared.icon(forFile: $0.path) }
        guard icons.count > 1 else { return icons.first }
        let side: CGFloat = 256
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            for (n, icon) in icons.enumerated().reversed() {
                let inset = CGFloat(icons.count - 1 - n) * 22
                let rect = NSRect(x: inset, y: CGFloat(n) * 22, width: side - CGFloat(icons.count - 1) * 22, height: side - CGFloat(icons.count - 1) * 22)
                icon.draw(in: rect)
            }
            return true
        }
    }

    /// The slower part, in the background: when it was last opened, a folder's item count and the
    /// kind's details (picture size, camera, duration, pages…).
    private func loadDetails(of url: URL, isFolder: Bool) {
        detailsTask = Task { [weak self] in
            // Arrowing through a folder: only the file the selection stops at is read
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let extra = await Task.detached(priority: .userInitiated) { () -> (opened: Date?, count: Int?, sections: [FileDetails.Section]) in
                let opened = MDItemCreateWithURL(nil, url as CFURL).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
                let count = isFolder ? (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") }.count : nil
                return (opened, count, await FileDetails.sections(for: url))
            }.value
            guard let self, !Task.isCancelled, self.urls == [url] else { return }
            var rows: [Row] = self.lines.map { ($0.label.stringValue, $0.value.stringValue, $0.extra) }
            if let opened = extra.opened { rows.append((L("Использован"), Self.date(opened), false)) }
            if let count = extra.count { rows.append((L("Содержит"), "\(count) \(plural(count, L("объект"), L("объекта"), L("объектов")))", false)) }
            rows += extra.sections.flatMap(\.rows).map { ($0.label, $0.value, true) }
            self.setLines(rows)
            self.needsLayout = true
        }
    }

    private typealias Row = (label: String, value: String, extra: Bool)

    private func setLines(_ rows: [Row]) {
        for line in lines {
            line.label.removeFromSuperview()
            line.value.removeFromSuperview()
        }
        separators.forEach { $0.removeFromSuperview() }
        lines = rows.map { title, value, extra in
            let label = NSTextField(wrappingLabelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = .systemFont(ofSize: 12, weight: .medium)
            field.alignment = .right
            field.isSelectable = true
            document.addSubview(label)
            document.addSubview(field)
            return (label, field, extra)
        }
        separators = rows.dropFirst().map { _ in
            let line = NSBox()
            line.boxType = .separator
            document.addSubview(line)
            return line
        }
        let hasExtra = rows.contains { $0.extra }
        moreButton.isHidden = !hasExtra
        moreButton.title = Self.showsMore ? L("Показать меньше") : L("Показать ещё")
    }

    /// Finder's way: «Четверг, 10 сентября 2026 г. в 21:15».
    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let text = formatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// `name` in at most two lines of `width`: the middle left out when it's longer (the start and
    /// the extension stay readable), as in Finder.
    private func twoLines(_ name: String, width: CGFloat) -> String {
        let font = nameLabel.font ?? .systemFont(ofSize: 17)
        func height(_ text: String) -> CGFloat {
            (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        }
        let limit = ceil(font.boundingRectForFont.height * 2) + 1
        guard height(name) > limit else { return name }
        let characters = Array(name)
        var (low, high) = (1, characters.count - 1)
        var best = String(characters.prefix(1)) + "…"
        while low <= high {
            let kept = (low + high) / 2
            let head = kept / 2 + kept % 2, tail = kept / 2
            let candidate = String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
            if height(candidate) <= limit { best = candidate; low = kept + 1 } else { high = kept - 1 }
        }
        return best
    }

    @objc private func toggleMore(_ sender: Any?) {
        Self.showsMore.toggle()
        moreButton.title = Self.showsMore ? L("Показать меньше") : L("Показать ещё")
        needsLayout = true
    }

    // MARK: - Tags

    /// The file's tags changed in the pane (with undo; Finder's other views follow).
    private func changeTags(_ change: ([FileTags.Tag]) -> [FileTags.Tag]) {
        guard urls.count == 1, let url = urls.first else { return }
        let current = FileTags.tags(of: url)
        var seen = Set<String>()
        let tags = change(current).filter { seen.insert($0.name).inserted }
        do { try FileTags.setTags(tags, on: url) } catch { NSAlert(error: error).runModal(); return }
        FileUndo.recordTags(before: [url: current])
        TagLibrary.merge(tags)
        tagStrip.tags = tags
        needsLayout = true
        NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
    }

    /// «Папка — 207,7 МБ»: everything inside added up, as Finder's pane shows it.
    private func addUpSize(of folder: URL, kind: String) {
        sizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let bytes = await Task.detached(priority: .utility) { () -> Int64? in
                guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
                var total: Int64 = 0, count = 0
                for case let url as URL in walker {
                    count += 1
                    if count % 500 == 0, Task.isCancelled { return nil }
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
                }
                return total
            }.value
            guard let self, let bytes, !Task.isCancelled, self.urls == [folder] else { return }
            self.kindLabel.stringValue = kind + " — " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            self.needsLayout = true
        }
    }

    // MARK: - Actions

    @objc private func openItems(_ sender: Any?) { onOpen?() }

    @objc private func shareItems(_ sender: NSButton) {
        NSSharingServicePicker(items: urls).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func showProperties(_ sender: Any?) { PropertiesWindowController.show(for: urls) }

    // MARK: - Layout

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        layoutDocument()
    }

    /// Top to bottom: the preview, the name, the kind, the buttons, the rows (label left, value
    /// right, both wrapping).
    private func layoutDocument() {
        let width = scrollView.contentView.frame.width
        let margin: CGFloat = 16
        let inner = max(width - margin * 2, 40)
        func height(of field: NSTextField, width: CGFloat) -> CGFloat {
            ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 16)
        }
        var y: CGFloat = margin
        if urls.isEmpty {
            placeholder.frame = NSRect(x: margin, y: max((scrollView.contentSize.height - 20) / 2, margin), width: inner, height: 20)
            document.frame = NSRect(x: 0, y: 0, width: width, height: scrollView.contentSize.height)
            return
        }
        var previewHeight = min(max(inner * 0.9, 120), Self.previewHeight)
        var area = NSRect(x: margin, y: y, width: inner, height: previewHeight)
        // A page or picture: the frame hugs it (no empty bands beside a narrow page), as wide as
        // the pane allows and as tall as its proportions make it
        if let image = thumbnailView.image, !previewBox.isHidden, image.size.width > 0, image.size.height > 0 {
            let scale = min(inner / image.size.width, min(inner * 1.5, Self.pictureHeight) / image.size.height)
            let size = NSSize(width: (image.size.width * scale).rounded() + 2, height: (image.size.height * scale).rounded() + 2)
            area = NSRect(x: margin + (inner - size.width) / 2, y: y, width: size.width, height: size.height)
            previewHeight = size.height
        }
        previewBox.frame = area
        let fitted = previewBox.bounds.insetBy(dx: 1, dy: 1)
        preview?.frame = fitted
        thumbnailView.frame = fitted
        textScroll.frame = fitted
        // Without a preview (folders, apps…) the icon takes the pane's whole width, as in Finder
        if previewBox.isHidden {
            area = NSRect(x: margin, y: y, width: inner, height: inner)
            previewHeight = inner
        }
        let iconSide = min(area.width, area.height)
        iconView.frame = NSRect(x: area.midX - iconSide / 2, y: area.midY - iconSide / 2, width: iconSide, height: iconSide)
        y += previewHeight + 12
        nameLabel.stringValue = twoLines(fullName, width: inner - 4)
        nameLabel.toolTip = nameLabel.stringValue == fullName ? nil : fullName
        let nameHeight = height(of: nameLabel, width: inner)
        nameLabel.frame = NSRect(x: margin, y: y, width: inner, height: nameHeight)
        y += nameHeight + 2
        let kindHeight = height(of: kindLabel, width: inner)
        kindLabel.frame = NSRect(x: margin, y: y, width: inner, height: kindHeight)
        y += kindHeight + 12
        let shown = buttons
        let buttonWidth: CGFloat = 76, buttonHeight: CGFloat = 40
        var x = (width - buttonWidth * CGFloat(shown.count)) / 2
        for button in shown {
            button.frame = NSRect(x: x, y: y, width: buttonWidth, height: buttonHeight)
            x += buttonWidth
        }
        y += buttonHeight + 14
        // «Информация» with «Показать ещё» on the right
        let headingHeight = height(of: infoHeading, width: inner)
        infoHeading.frame = NSRect(x: margin, y: y, width: inner / 2, height: headingHeight)
        let moreWidth = ceil(moreButton.fittingSize.width)
        moreButton.frame = NSRect(x: margin + inner - moreWidth, y: y, width: moreWidth, height: headingHeight)
        y += headingHeight + 6
        let shownLines = lines.filter { !$0.extra || Self.showsMore }
        for line in lines {
            let shown = !line.extra || Self.showsMore
            line.label.isHidden = !shown
            line.value.isHidden = !shown
        }
        for separator in separators { separator.isHidden = true }
        for (n, line) in shownLines.enumerated() {
            if n > 0, separators.indices.contains(n - 1) {
                separators[n - 1].isHidden = false
                separators[n - 1].frame = NSRect(x: margin, y: y, width: inner, height: 1)
                y += 1
            }
            y += 5
            // The label as wide as it needs (up to half), the value takes the rest
            let labelWidth = min(ceil(line.label.cell?.cellSize.width ?? 60), (inner * 0.5).rounded())
            let labelHeight = height(of: line.label, width: labelWidth)
            let valueWidth = inner - labelWidth - 10
            let valueHeight = height(of: line.value, width: valueWidth)
            line.label.frame = NSRect(x: margin, y: y, width: labelWidth, height: labelHeight)
            line.value.frame = NSRect(x: margin + labelWidth + 10, y: y, width: valueWidth, height: valueHeight)
            y += max(labelHeight, valueHeight) + 5
        }
        if !tagStrip.isHidden {
            y += 14
            tagsHeading.frame = NSRect(x: margin, y: y, width: inner, height: height(of: tagsHeading, width: inner))
            y += tagsHeading.frame.height + 6
            let stripHeight = tagStrip.arrange(width: inner, apply: false)
            tagStrip.frame = NSRect(x: margin, y: y, width: inner, height: stripHeight)
            y += stripHeight
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y + margin, scrollView.contentSize.height))
    }

    #if DEBUG
    var debugName: String { nameLabel.stringValue }
    var debugKind: String { kindLabel.stringValue }
    var debugLines: [String] { lines.map { ($0.extra ? "+" : "") + $0.label.stringValue + ": " + $0.value.stringValue } }
    var debugShownLines: Int { lines.filter { !$0.label.isHidden }.count }
    var debugMore: String { moreButton.isHidden ? "-" : moreButton.title }
    func debugToggleMore() { toggleMore(nil) }
    var debugTagStrip: TagStrip? { tagStrip.isHidden ? nil : tagStrip }
    var debugIconWidth: Int { iconView.isHidden ? 0 : Int(iconView.frame.width) }
    var debugShowsLivePreview: Bool { preview?.superview != nil }
    var debugShowsThumbnail: Bool { !previewBox.isHidden && thumbnailView.image != nil }
    var debugText: String { textScroll.isHidden ? "" : String(textView.string.prefix(30)) }
    var debugButtons: [String] { buttons.map(\.title) }
    var debugGeometry: String {
        "pane \(Int(frame.width)), clip \(Int(scrollView.contentView.frame.width)), scroller \(scrollView.verticalScroller.map { "\(Int($0.frame.width)) \($0.isHidden ? "hidden" : "shown") style \($0.scrollerStyle.rawValue)" } ?? "-"), name right \(Int(nameLabel.frame.maxX)), doc \(Int(document.frame.width))"
    }
    #endif
}

/// The files and the preview pane beside them. The pane keeps its width as the window resizes
/// (the files give way, down to a minimum), its divider is dragged within limits, and it is gone
/// — divider and all — while the pane is hidden.
final class PreviewSplitView: NSSplitView, NSSplitViewDelegate {
    let pane: PreviewPane
    private var paneWidth = PreviewPane.width
    private static let minimumFilesWidth: CGFloat = 300

    init(files: NSView, pane: PreviewPane) {
        self.pane = pane
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(files)
        addArrangedSubview(pane)
    }

    required init?(coder: NSCoder) { fatalError() }

    var isPaneShown: Bool {
        get { !pane.isHidden }
        set {
            pane.isHidden = !newValue
            adjustSubviews()
            layoutPanes()
            needsLayout = true
            needsDisplay = true
        }
    }

    private var widestPane: CGFloat {
        min(PreviewPane.maximumWidth, bounds.width - dividerThickness - Self.minimumFilesWidth)
    }

    private func layoutPanes() {
        guard subviews.count == 2 else { return }
        let (files, side) = (subviews[0], subviews[1])
        hideDividerWithPane()
        guard !side.isHidden else {
            files.frame = bounds
            return
        }
        let width = max(min(paneWidth, widestPane), PreviewPane.minimumWidth)
        side.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        files.frame = NSRect(x: 0, y: 0, width: max(bounds.width - width - dividerThickness, 0), height: bounds.height)
    }

    override func layout() {
        super.layout()
        hideDividerWithPane()
    }

    /// The split view draws its divider in a layer of its own and leaves it where it was when the
    /// pane goes away: its line stayed over the files.
    private func hideDividerWithPane() {
        let backing = Set(subviews.compactMap(\.layer).map(ObjectIdentifier.init))
        for divider in layer?.sublayers ?? [] where !backing.contains(ObjectIdentifier(divider)) { divider.isHidden = pane.isHidden }
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { layoutPanes() }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        bounds.width - dividerThickness - max(widestPane, PreviewPane.minimumWidth)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        bounds.width - dividerThickness - PreviewPane.minimumWidth
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { pane.isHidden }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        pane.isHidden ? .zero : proposedEffectiveRect
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only the user's drag counts (not window resizing or showing the pane)
        guard !pane.isHidden, window?.inLiveResize == false, NSApp.currentEvent?.type == .leftMouseDragged,
              subviews.count == 2 else { return }
        paneWidth = subviews[1].frame.width
        PreviewPane.width = paneWidth
    }
}

/// The rounded frame the preview sits in, as in Finder's preview pane.
private final class PreviewBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
        }
    }
}
