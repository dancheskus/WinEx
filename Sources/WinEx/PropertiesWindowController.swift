import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// "Свойства" (⌘I / ⌥↩): one file or a group. In WinEx's own look (the translucent material of
/// its menus, rounded cards, roomy rows) with tabs like Explorer's: «Общие» (type, app, place,
/// size, dates, attributes), «Подробно» (what matters for the kind of file: picture size and
/// camera settings, durations and codecs, pages, app version, where it was downloaded from) and «Доступ» (owner and permissions).
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [PropertiesWindowController] = []

    static func show(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = PropertiesWindowController(urls: urls)
        open.append(controller)
        NSApp.activate()
        controller.showWindow(nil)
    }

    private let urls: [URL]
    private let cancel = CancelFlag()
    private var isSingle: Bool { urls.count == 1 }
    private var single: URL { urls[0] }

    private let subtitle = NSTextField(labelWithString: "")
    private let sizeValue = PropertiesUI.value(L("Вычисляется…"))
    private let allocatedValue = PropertiesUI.value(L("Вычисляется…"))
    private let containsValue = PropertiesUI.value(L("Вычисляется…"))
    private let appValue = PropertiesUI.value("")
    private let appIcon = NSImageView()
    private let lockedSwitch = NSSwitch()
    private let hiddenSwitch = NSSwitch()

    private let tabBar = PropertiesTabBar()
    private let pageHolder = NSView()
    private var pages: [NSView] = []
    private let detailsStack = PropertiesUI.stack()
    private var detailsLoaded = false

    static let width: CGFloat = 520

    private init(urls: [URL]) {
        self.urls = urls
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 500),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        // An empty unified toolbar: the regular window buttons with room around them, like
        // WinEx's windows
        let toolbar = NSToolbar(identifier: "WinExProperties")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.title = urls.count == 1 ? L("Свойства: %@", urls[0].displayName)
            : L("Свойства: %@ %@", urls.count, plural(urls.count, L("объект"), L("объекта"), L("объектов")))
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
        computeSizes()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func build() {
        guard let window else { return }
        // The material of WinEx's menus
        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active

        var titles = [L("Общие")]
        pages = [generalPage()]
        if isSingle, !single.isBrowsableDirectory {
            titles.append(L("Подробно"))
            pages.append(detailsPage())
        }
        if isSingle {
            titles.append(L("Доступ"))
            pages.append(accessPage())
        }
        tabBar.titles = titles
        tabBar.onSelect = { [weak self] in self?.showPage($0) }
        tabBar.isHidden = titles.count == 1

        let root = NSStackView(views: [header(), tabBar, pageHolder])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 60, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.widthAnchor.constraint(equalToConstant: Self.width),
            pageHolder.widthAnchor.constraint(equalToConstant: Self.width - 48),
        ])
        window.contentView = background
        showPage(0)
    }

    private func showPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        tabBar.selected = index
        pageHolder.subviews.forEach { $0.removeFromSuperview() }
        let page = pages[index]
        page.translatesAutoresizingMaskIntoConstraints = false
        pageHolder.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pageHolder.topAnchor),
            page.leadingAnchor.constraint(equalTo: pageHolder.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageHolder.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: pageHolder.bottomAnchor),
        ])
        if pages.count > 1, index == 1, !detailsLoaded { loadDetails() }
        fitWindow()
    }

    /// The window follows the page's height (keeping its top edge where it is).
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = min(content.fittingSize.height, (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: height)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func header() -> NSView {
        let icon = NSImageView(image: isSingle ? FileItem(url: single).icon
                                               : NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        if isSingle {
            // Finder's look: documents as rounded pages, pictures as rounded cards
            let request = QLThumbnailGenerator.Request(fileAt: single, size: CGSize(width: 72, height: 72), scale: 2, representationTypes: .thumbnail)
            request.iconMode = true
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let image = representation?.nsImage else { return }
                DispatchQueue.main.async { icon.image = image }
            }
        }
        let folders = urls.filter(\.isBrowsableDirectory).count
        let files = urls.count - folders
        let name = NSTextField(wrappingLabelWithString: isSingle ? single.displayName
            : [files > 0 ? "\(files) \(plural(files, L("файл"), L("файла"), L("файлов")))" : nil,
               folders > 0 ? "\(folders) \(plural(folders, L("папка"), L("папки"), L("папок")))" : nil].compactMap { $0 }.joined(separator: ", "))
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.isSelectable = true
        name.maximumNumberOfLines = 3
        name.preferredMaxLayoutWidth = Self.width - 48 - 72 - 16
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.stringValue = typeDescription
        let texts = NSStackView(views: [name, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4
        let header = NSStackView(views: [icon, texts])
        header.spacing = 16
        header.alignment = .centerY
        return header
    }

    private var typeDescription: String {
        let types = Set(urls.compactMap { (try? $0.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription })
        return types.count == 1 ? types.first ?? "" : L("Разные типы")
    }

    // MARK: - «Общие»

    private func generalPage() -> NSView {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .creationDateKey, .contentModificationDateKey,
                                         .contentAccessDateKey, .addedToDirectoryDateKey, .isUserImmutableKey, .isHiddenKey,
                                         .isVolumeKey, .volumeLocalizedFormatDescriptionKey]
        let values = urls.map { try? $0.resourceValues(forKeys: keys) }
        let page = PropertiesUI.stack()

        var about: [NSView] = [PropertiesUI.row(L("Тип"), PropertiesUI.value(typeDescription))]
        if isSingle, values[0]?.isVolume == true, let format = values[0]?.volumeLocalizedFormatDescription {
            about.append(PropertiesUI.row(L("Файловая система"), PropertiesUI.value(format)))
        }
        if isSingle, !(values[0]?.isDirectory ?? false) || (values[0]?.isPackage ?? false) {
            appIcon.imageScaling = .scaleProportionallyUpOrDown
            appIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            appIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let change = PropertiesUI.linkButton(L("Изменить…"), target: self, action: #selector(changeDefaultApp(_:)))
            let line = NSStackView(views: [appIcon, appValue, change])
            line.spacing = 8
            updateDefaultApp()
            about.append(PropertiesUI.row(L("Открывается в"), line))
        }
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        let place = PropertiesUI.value(parents.count == 1 ? Self.shortPath(parents.first ?? "") : L("Разные папки"))
        place.toolTip = parents.first
        if parents.count == 1 {
            let show = PropertiesUI.linkButton(L("Показать"), target: self, action: #selector(revealItem(_:)))
            let line = NSStackView(views: [place, show])
            line.spacing = 8
            about.append(PropertiesUI.row(L("Расположение"), line))
        } else {
            about.append(PropertiesUI.row(L("Расположение"), place))
        }
        page.addArrangedSubview(PropertiesUI.card(nil, about))

        var sizes = [PropertiesUI.row(L("Размер"), sizeValue), PropertiesUI.row(L("На диске"), allocatedValue)]
        if urls.contains(where: \.isBrowsableDirectory) || !isSingle { sizes.append(PropertiesUI.row(L("Содержит"), containsValue)) }
        page.addArrangedSubview(PropertiesUI.card(L("Размер"), sizes))

        if isSingle, let v = values[0] {
            let date = { (d: Date?) in d.map(FileDetails.longDate) ?? "—" }
            var dates = [PropertiesUI.row(L("Создан"), PropertiesUI.value(date(v.creationDate))),
                         PropertiesUI.row(L("Изменён"), PropertiesUI.value(date(v.contentModificationDate))),
                         PropertiesUI.row(L("Открыт"), PropertiesUI.value(date(v.contentAccessDate)))]
            if let added = v.addedToDirectoryDate { dates.append(PropertiesUI.row(L("Добавлен"), PropertiesUI.value(date(added)))) }
            page.addArrangedSubview(PropertiesUI.card(L("Даты"), dates))
        }

        // One file: its attributes are on «Доступ»; several: here (there's no «Доступ» for a group)
        if !isSingle { page.addArrangedSubview(attributesCard(values)) }
        return page
    }

    /// «Только чтение», «Скрытый».
    private func attributesCard(_ values: [URLResourceValues?]) -> NSView {
        func state(_ flags: [Bool?]) -> NSControl.StateValue {
            let set = Set(flags.map { $0 ?? false })
            return set.count > 1 ? .mixed : (set.first == true ? .on : .off)
        }
        lockedSwitch.state = state(values.map { $0?.isUserImmutable })
        lockedSwitch.target = self
        lockedSwitch.action = #selector(toggleLocked(_:))
        hiddenSwitch.state = state(values.map { $0?.isHidden })
        hiddenSwitch.target = self
        hiddenSwitch.action = #selector(toggleHidden(_:))
        // A leading dot hides a file by name; the flag can't change that
        hiddenSwitch.isEnabled = !urls.contains { $0.lastPathComponent.hasPrefix(".") }
        for control in [lockedSwitch, hiddenSwitch] { control.controlSize = .small }
        return PropertiesUI.card(L("Атрибуты"), [
            PropertiesUI.row(L("Только чтение"), lockedSwitch, hint: L("Защищено от изменения и удаления")),
            PropertiesUI.row(L("Скрытый"), hiddenSwitch, hint: L("Не виден, пока скрытые файлы не показаны")),
        ])
    }

    /// "~/Desktop" for places in the home folder.
    private static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - «Подробно»

    private func detailsPage() -> NSView {
        let loading = PropertiesUI.value(L("Сбор сведений…"))
        loading.textColor = .secondaryLabelColor
        detailsStack.addArrangedSubview(loading)
        return detailsStack
    }

    private func loadDetails() {
        detailsLoaded = true
        let url = single
        Task { [weak self] in
            let sections = await Task.detached(priority: .userInitiated) { await FileDetails.sections(for: url) }.value
            guard let self else { return }
            detailsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for section in sections {
                let rows = section.rows.map { row -> NSView in
                    let value: NSView = row.link.map { link in
                        let button = PropertiesUI.linkButton(row.value, target: self, action: #selector(PropertiesWindowController.openLink(_:)))
                        button.toolTip = link.absoluteString
                        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
                        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                        return button
                    } ?? PropertiesUI.value(row.value)
                    return PropertiesUI.row(row.label, value)
                }
                detailsStack.addArrangedSubview(PropertiesUI.card(section.title, rows))
            }
            if detailsStack.arrangedSubviews.isEmpty {
                let none = PropertiesUI.value(L("Других сведений об этом объекте нет"))
                none.textColor = .secondaryLabelColor
                detailsStack.addArrangedSubview(none)
            }
            fitWindow()
        }
    }

    @objc private func openLink(_ sender: NSButton) {
        if let link = sender.toolTip.flatMap(URL.init(string:)) { NSWorkspace.shared.open(link) }
    }

    // MARK: - «Доступ»

    private func accessPage() -> NSView {
        let page = PropertiesUI.stack()
        let attributes = (try? FileManager.default.attributesOfItem(atPath: single.path)) ?? [:]
        let owner = attributes[.ownerAccountName] as? String ?? "—"
        let group = attributes[.groupOwnerAccountName] as? String ?? "—"
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let me = NSUserName()
        page.addArrangedSubview(PropertiesUI.card(nil, [
            PropertiesUI.row(L("Владелец"), PropertiesUI.value(owner + (owner == me ? L(" (вы)") : ""))),
            PropertiesUI.row(L("Группа"), PropertiesUI.value(group)),
        ]))
        let isFolder = single.isBrowsableDirectory
        func describe(_ bits: Int) -> String {
            let read = bits & 4 != 0, write = bits & 2 != 0, run = bits & 1 != 0
            var text = read && write ? L("Чтение и запись") : read ? L("Только чтение") : write ? L("Только запись") : L("Нет доступа")
            if run && !isFolder { text += L(", запуск") }
            if !run && isFolder && read { text += L(" (содержимое не открыть)") }
            return text
        }
        page.addArrangedSubview(PropertiesUI.card(L("Права"), [
            PropertiesUI.row(L("Владелец"), PropertiesUI.value(describe(mode >> 6 & 7))),
            PropertiesUI.row(L("Группа"), PropertiesUI.value(describe(mode >> 3 & 7))),
            PropertiesUI.row(L("Остальные"), PropertiesUI.value(describe(mode & 7))),
            PropertiesUI.row(L("Код"), PropertiesUI.value(String(mode & 0o777, radix: 8))),
        ]))
        let access = FileManager.default
        let yours = [access.isReadableFile(atPath: single.path) ? L("читать") : nil,
                     access.isWritableFile(atPath: single.path) ? L("изменять") : nil,
                     access.isDeletableFile(atPath: single.path) ? L("удалять") : nil].compactMap { $0 }
        let flags = try? single.resourceValues(forKeys: [.isUserImmutableKey, .isHiddenKey])
        page.addArrangedSubview(attributesCard([flags]))
        page.addArrangedSubview(PropertiesUI.card(L("Ваши права"), [
            PropertiesUI.row(L("Вы можете"), PropertiesUI.value(yours.isEmpty ? L("Ничего") : yours.joined(separator: ", ").capitalizedFirst)),
        ]))
        return page
    }

    // MARK: - Sizes (background)

    private func computeSizes() {
        let urls = self.urls, cancel = self.cancel
        let volumeValues = isSingle ? try? single.resourceValues(forKeys: [.isVolumeKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]) : nil
        if volumeValues?.isVolume == true, let total = volumeValues?.volumeTotalCapacity, let free = volumeValues?.volumeAvailableCapacity {
            // Whole disks: capacity instead of walking every file
            sizeValue.stringValue = L("Ёмкость ") + Self.bytes(Int64(total))
            allocatedValue.stringValue = L("Свободно ") + Self.bytes(Int64(free))
            containsValue.stringValue = "—"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
            var size: Int64 = 0, allocated: Int64 = 0, files = 0, folders = 0
            var lastReport = Date()
            func add(_ values: URLResourceValues?) {
                size += Int64(values?.fileSize ?? 0)
                allocated += Int64(values?.totalFileAllocatedSize ?? 0)
            }
            for url in urls {
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { files += 1; add(values); continue }
                if values?.isPackage != true { folders += 1 } else { files += 1 }
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { continue }
                for case let child as URL in enumerator {
                    if cancel.isCancelled { return }
                    let childValues = try? child.resourceValues(forKeys: keys)
                    if childValues?.isDirectory == true { folders += 1 } else { files += 1; add(childValues) }
                    if Date().timeIntervalSince(lastReport) > 0.25 {
                        lastReport = Date()
                        let snapshot = (size, allocated, files, folders)
                        DispatchQueue.main.async { self?.showSizes(snapshot, done: false) }
                    }
                }
            }
            let result = (size, allocated, files, folders)
            DispatchQueue.main.async { self?.showSizes(result, done: true) }
        }
    }

    private func showSizes(_ values: (size: Int64, allocated: Int64, files: Int, folders: Int), done: Bool) {
        let suffix = done ? "" : "…"
        sizeValue.stringValue = Self.bytes(values.size) + suffix
        allocatedValue.stringValue = Self.bytes(values.allocated) + suffix
        // The selected folders themselves aren't "contained"
        let folders = max(0, values.folders - urls.filter { $0.isBrowsableDirectory }.count)
        let files = isSingle && !single.isBrowsableDirectory ? 0 : values.files - (isSingle ? 0 : urls.filter { !$0.isBrowsableDirectory }.count)
        containsValue.stringValue = "\(files) \(plural(files, L("файл"), L("файла"), L("файлов"))), \(folders) \(plural(folders, L("папка"), L("папки"), L("папок")))" + suffix
        if done { subtitle.stringValue = typeDescription + " · " + ByteCountFormatter.string(fromByteCount: values.size, countStyle: .file) }
    }

    /// "12,3 МБ (12 345 678 байт)"
    private static func bytes(_ count: Int64) -> String {
        let number = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return "\(ByteCountFormatter.string(fromByteCount: count, countStyle: .file)) (\(number) \(plural(Int(count % 1000), L("байт"), L("байта"), L("байт"))))"
    }

    // MARK: - Actions

    private func updateDefaultApp() {
        if let app = NSWorkspace.shared.urlForApplication(toOpen: single) {
            let name = FileManager.default.displayName(atPath: app.path)
            appValue.stringValue = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            appIcon.image = NSWorkspace.shared.icon(forFile: app.path)
            appIcon.isHidden = false
        } else {
            appValue.stringValue = L("Не назначено")
            appIcon.isHidden = true
        }
    }

    @objc private func changeDefaultApp(_ sender: Any?) {
        guard let type = (try? single.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return }
        let panel = NSOpenPanel()
        panel.title = L("Открывать файлы «%@» в программе", type.localizedDescription ?? single.pathExtension)
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard let window, panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { [weak self] error in
            DispatchQueue.main.async {
                if let error { NSAlert(error: error).beginSheetModal(for: window) }
                self?.updateDefaultApp()
            }
        }
    }

    @objc private func revealItem(_ sender: Any?) {
        AppDelegate.shared.reveal(single)
    }

    @objc private func toggleLocked(_ sender: NSSwitch) {
        setFlag(\.isUserImmutable, sender.state == .on)
    }

    @objc private func toggleHidden(_ sender: NSSwitch) {
        setFlag(\.isHidden, sender.state == .on)
    }

    private func setFlag(_ key: WritableKeyPath<URLResourceValues, Bool?>, _ on: Bool) {
        for url in urls {
            var values = URLResourceValues()
            values[keyPath: key] = on
            var mutable = url
            do { try mutable.setResourceValues(values) } catch { NSAlert(error: error).runModal(); return }
        }
        NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
    }

    // MARK: - Window

    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        cancel.cancel()
        Self.open.removeAll { $0 === self }
    }
}

/// The building blocks of the properties window.
@MainActor
enum PropertiesUI {
    static func stack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
    }

    static func value(_ text: String) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text)
        value.font = .systemFont(ofSize: 13)
        value.isSelectable = true
        value.maximumNumberOfLines = 3
        value.lineBreakMode = .byTruncatingMiddle
        value.preferredMaxLayoutWidth = PropertiesWindowController.width - 48 - 28 - labelWidth - 12
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return value
    }

    static func linkButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.contentTintColor = .linkColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 13)])
        return button
    }

    static let labelWidth: CGFloat = 150

    /// "Label   value" (with an optional grey hint under the label).
    static func row(_ label: String, _ value: NSView, hint: String? = nil) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 13)
        title.textColor = .secondaryLabelColor
        var left: NSView = title
        if let hint {
            let small = NSTextField(wrappingLabelWithString: hint)
            small.font = .systemFont(ofSize: 11)
            small.textColor = .tertiaryLabelColor
            small.preferredMaxLayoutWidth = PropertiesWindowController.width - 48 - 28 - 80
            let texts = NSStackView(views: [title, small])
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 2
            left = texts
        }
        let row = NSView()
        for view in [left, value] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        var constraints = [
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            left.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 9),
            left.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -9),
            value.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 9),
            value.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -9),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ]
        if hint != nil {
            // A switch with an explanation: text on the left, the switch at the right edge
            constraints += [
                left.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                value.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                value.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                left.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -12),
            ]
        } else {
            constraints += [
                left.widthAnchor.constraint(equalToConstant: labelWidth),
                value.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 12),
                value.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -14),
            ]
            if value is NSTextField {
                // Text that may wrap: the label stays on its first line
                constraints += [left.firstBaselineAnchor.constraint(equalTo: value.firstBaselineAnchor),
                                left.topAnchor.constraint(equalTo: value.topAnchor),
                                value.centerYAnchor.constraint(equalTo: row.centerYAnchor).withPriority(.defaultLow)]
            } else {
                // A line of controls (an app icon and a button, a link): both centred
                constraints += [left.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                                value.centerYAnchor.constraint(equalTo: row.centerYAnchor)]
            }
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// A titled group of rows on a rounded, lightly filled card, with thin lines between rows.
    static func card(_ title: String?, _ rows: [NSView]) -> NSView {
        let box = CardView()
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                inner.addArrangedSubview(line)
                line.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 14).isActive = true
                line.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -14).isActive = true
            }
            inner.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            box.widthAnchor.constraint(equalToConstant: PropertiesWindowController.width - 48),
        ])
        guard let title else { return box }
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let group = NSStackView(views: [heading, box])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        group.setCustomSpacing(6, after: heading)
        heading.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 6).isActive = true
        return group
    }
}

private final class CardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 1
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).stroke()
    }
}

/// Capsule tabs, like the command bar's buttons.
final class PropertiesTabBar: NSView {
    var titles: [String] = [] { didSet { rebuild() } }
    var selected = 0 { didSet { buttons.enumerated().forEach { $0.element.isChosen = $0.offset == selected } } }
    var onSelect: ((Int) -> Void)?
    private var buttons: [Pill] = []

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        buttons = titles.enumerated().map { index, title in
            let pill = Pill(title: title)
            pill.onClick = { [weak self] in self?.onSelect?(index) }
            return pill
        }
        let stack = NSStackView(views: buttons)
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private final class Pill: NSView {
        var onClick: (() -> Void)?
        var isChosen = false { didSet { label.textColor = isChosen ? .labelColor : .secondaryLabelColor; needsDisplay = true } }
        private let label: NSTextField
        private var hovering = false { didSet { needsDisplay = true } }

        init(title: String) {
            label = NSTextField(labelWithString: title)
            super.init(frame: .zero)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                widthAnchor.constraint(equalTo: label.widthAnchor, constant: 32),
                heightAnchor.constraint(equalToConstant: 32),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }
        override func mouseDown(with event: NSEvent) { onClick?() }

        override func draw(_ dirtyRect: NSRect) {
            guard isChosen || hovering else { return }
            NSColor.labelColor.withAlphaComponent(isChosen ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Notification.Name {
    /// Tags or file flags changed outside a directory write (extended attributes don't touch the folder).
    static let fileTagsChanged = Notification.Name("WinExFileTagsChanged")
}
