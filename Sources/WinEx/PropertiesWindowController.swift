import AppKit
import UniformTypeIdentifiers

/// "Свойства" (⌘I / ⌥↩), like Explorer's Properties: one file or a group of them.
/// Folder sizes are counted in the background; tags and attributes are applied immediately.
final class PropertiesWindowController: NSWindowController, NSWindowDelegate, NSTokenFieldDelegate {
    private static var open: [PropertiesWindowController] = []

    static func show(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = PropertiesWindowController(urls: urls)
        open.append(controller)
        NSApp.activate()
        controller.showWindow(nil)
    }

    private let urls: [URL]
    private var cancelled = false
    private let sizeLabel = PropertiesWindowController.value("Вычисляется…")
    private let allocatedLabel = PropertiesWindowController.value("Вычисляется…")
    private let containsLabel = PropertiesWindowController.value("Вычисляется…")
    private let appLabel = PropertiesWindowController.value("")
    private let tagsField = NSTokenField()
    private let lockedBox = NSButton(checkboxWithTitle: "Только чтение (защищено)", target: nil, action: nil)
    private let hiddenBox = NSButton(checkboxWithTitle: "Скрытый", target: nil, action: nil)
    private var tagsAtOpen: [[FileTags.Tag]] = []

    private var isSingle: Bool { urls.count == 1 }
    private var single: URL { urls[0] }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    private init(urls: [URL]) {
        self.urls = urls
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                             styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        window.title = urls.count == 1 ? "Свойства: \(urls[0].displayName)"
            : "Свойства: \(urls.count) \(plural(urls.count, "объект", "объекта", "объектов"))"
        build()
        window.center()
        computeSizes()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private static func value(_ text: String) -> NSTextField {
        let value = NSTextField(labelWithString: text)
        value.isSelectable = true
        value.lineBreakMode = .byTruncatingMiddle
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return value
    }

    private func build() {
        let values = urls.map { try? $0.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey,
            .contentAccessDateKey, .isUserImmutableKey, .isHiddenKey, .isVolumeKey, .contentTypeKey,
        ]) }
        let folderCount = zip(urls, values).filter { ($0.1?.isDirectory ?? false) && !($0.1?.isPackage ?? false) }.count

        // Header: icon + name
        let icon = NSImageView(image: isSingle ? FileItem(url: single).icon
                                               : NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let fileCount = urls.count - folderCount
        let title = NSTextField(labelWithString: isSingle ? single.displayName
            : "\(fileCount) \(plural(fileCount, "файл", "файла", "файлов")), \(folderCount) \(plural(folderCount, "папка", "папки", "папок"))")
        title.font = .boldSystemFont(ofSize: 14)
        title.isSelectable = true
        title.lineBreakMode = .byTruncatingMiddle
        let header = NSStackView(views: [icon, title])
        header.spacing = 12

        var rows: [[NSView]] = []
        var sectionStarts: [Int] = []
        func row(_ name: String, _ view: NSView) { rows.append([Self.label(name), view]) }
        func separator() { sectionStarts.append(rows.count) }

        let types = Set(values.compactMap { $0?.localizedTypeDescription })
        row("Тип:", Self.value(types.count == 1 ? types.first! : "Разные типы"))

        if isSingle, !(values[0]?.isDirectory ?? false) || (values[0]?.isPackage ?? false) {
            let change = NSButton(title: "Изменить…", target: self, action: #selector(changeDefaultApp(_:)))
            change.controlSize = .small
            let appRow = NSStackView(views: [appLabel, change])
            appRow.spacing = 8
            updateDefaultApp()
            row("Приложение:", appRow)
        }

        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        row("Расположение:", Self.value(parents.count == 1 ? parents.first! : "Разные папки"))
        separator()
        row("Размер:", sizeLabel)
        row("На диске:", allocatedLabel)
        if folderCount > 0 || !isSingle { row("Содержит:", containsLabel) }

        if isSingle, let v = values[0] {
            separator()
            let date = { (d: Date?) in d.map(Self.dateFormatter.string(from:)) ?? "—" }
            row("Создан:", Self.value(date(v.creationDate)))
            row("Изменён:", Self.value(date(v.contentModificationDate)))
            row("Открыт:", Self.value(date(v.contentAccessDate)))
        }

        separator()
        tagsAtOpen = urls.map(FileTags.tags(of:))
        let common = tagsAtOpen.dropFirst().reduce(Set(tagsAtOpen.first?.map(\.name) ?? [])) { $0.intersection($1.map(\.name)) }
        tagsField.objectValue = (tagsAtOpen.first ?? []).map(\.name).filter(common.contains)
        tagsField.placeholderString = isSingle ? "Добавьте теги" : "Общие теги"
        tagsField.delegate = self
        tagsField.tokenStyle = .rounded
        tagsField.target = self
        tagsField.action = #selector(tagsChanged(_:))
        tagsField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        row("Теги:", tagsField)

        func state(_ flags: [Bool?]) -> NSControl.StateValue {
            let set = Set(flags.map { $0 ?? false })
            return set.count > 1 ? .mixed : (set.first == true ? .on : .off)
        }
        for box in [lockedBox, hiddenBox] { box.allowsMixedState = !isSingle; box.target = self }
        lockedBox.state = state(values.map { $0?.isUserImmutable })
        lockedBox.action = #selector(toggleLocked(_:))
        hiddenBox.state = state(values.map { $0?.isHidden })
        hiddenBox.action = #selector(toggleHidden(_:))
        // A leading dot hides a file by name; the flag can't change that
        hiddenBox.isEnabled = !urls.contains { $0.lastPathComponent.hasPrefix(".") }
        let attributes = NSStackView(views: [lockedBox, hiddenBox])
        attributes.orientation = .vertical
        attributes.alignment = .leading
        attributes.spacing = 4
        row("Атрибуты:", attributes)

        let grid = NSGridView(views: rows)
        grid.columnSpacing = 10
        grid.rowSpacing = 7
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 110
        for i in sectionStarts where i < grid.numberOfRows {
            grid.row(at: i).topPadding = 10
        }

        let ok = NSButton(title: "OK", target: self, action: #selector(closeWindow(_:)))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), ok])

        let stack = NSStackView(views: [header, NSBox.separatorLine(), grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        for view in [stack.views[1], buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window?.contentView = stack
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        // Size the window to its content, otherwise the grid spreads the spare height between rows
        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(stack.fittingSize)
    }

    // MARK: - Sizes (background)

    private func computeSizes() {
        let urls = self.urls
        let volumeValues = isSingle ? try? single.resourceValues(forKeys: [.isVolumeKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]) : nil
        if volumeValues?.isVolume == true, let total = volumeValues?.volumeTotalCapacity, let free = volumeValues?.volumeAvailableCapacity {
            // Whole disks: capacity instead of walking every file
            sizeLabel.stringValue = "Ёмкость: " + Self.bytes(Int64(total))
            allocatedLabel.stringValue = "Доступно: " + Self.bytes(Int64(free))
            containsLabel.stringValue = "—"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
            var size: Int64 = 0, allocated: Int64 = 0, files = 0, folders = 0
            var lastReport = Date()
            func add(_ url: URL, _ values: URLResourceValues?) {
                size += Int64(values?.fileSize ?? 0)
                allocated += Int64(values?.totalFileAllocatedSize ?? 0)
            }
            for url in urls {
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { files += 1; add(url, values); continue }
                if values?.isPackage != true { folders += 1 } else { files += 1 }
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { continue }
                for case let child as URL in enumerator {
                    if self?.cancelled ?? true { return }
                    let childValues = try? child.resourceValues(forKeys: keys)
                    if childValues?.isDirectory == true { folders += 1 } else { files += 1; add(child, childValues) }
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
        sizeLabel.stringValue = Self.bytes(values.size) + suffix
        allocatedLabel.stringValue = Self.bytes(values.allocated) + suffix
        // The selected folders themselves aren't "contained"
        let folders = max(0, values.folders - urls.filter { $0.isBrowsableDirectory }.count)
        let files = isSingle && !single.isBrowsableDirectory ? 0 : values.files - (isSingle ? 0 : urls.filter { !$0.isBrowsableDirectory }.count)
        containsLabel.stringValue = "\(files) \(plural(files, "файл", "файла", "файлов")), \(folders) \(plural(folders, "папка", "папки", "папок"))" + suffix
    }

    /// "12,3 МБ (12 345 678 байт)"
    private static func bytes(_ count: Int64) -> String {
        let number = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return "\(ByteCountFormatter.string(fromByteCount: count, countStyle: .file)) (\(number) \(plural(Int(count % 1000), "байт", "байта", "байт")))"
    }

    // MARK: - Default app

    private func updateDefaultApp() {
        if let app = NSWorkspace.shared.urlForApplication(toOpen: single) {
            let name = FileManager.default.displayName(atPath: app.path)
            appLabel.stringValue = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        } else {
            appLabel.stringValue = "Не назначено"
        }
    }

    @objc private func changeDefaultApp(_ sender: Any?) {
        guard let type = (try? single.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return }
        let panel = NSOpenPanel()
        panel.title = "Открывать файлы «\(type.localizedDescription ?? single.pathExtension)» в программе"
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

    // MARK: - Tags and attributes

    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                    indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        FileTags.favorites.map(\.name).filter { $0.localizedCaseInsensitiveContains(substring) }
    }

    @objc private func tagsChanged(_ sender: Any?) {
        applyTags()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        applyTags()
    }

    /// For a group only the shared tags are shown: removing one removes it everywhere, adding adds everywhere.
    private func applyTags() {
        let names = (tagsField.objectValue as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let shown = tagsAtOpen.dropFirst().reduce(Set(tagsAtOpen.first?.map(\.name) ?? [])) { $0.intersection($1.map(\.name)) }
        let added = names.filter { !shown.contains($0) }
        let removed = shown.subtracting(names)
        guard !added.isEmpty || !removed.isEmpty else { return }
        let known = tagsAtOpen.flatMap { $0 }
        for (index, url) in urls.enumerated() {
            var tags = FileTags.tags(of: url).filter { !removed.contains($0.name) }
            for name in added where !tags.contains(where: { $0.name == name }) {
                tags.append(FileTags.tag(named: name, knownTags: known))
            }
            do { try FileTags.setTags(tags, on: url) } catch { NSAlert(error: error).runModal(); return }
            tagsAtOpen[index] = tags
        }
        NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
    }

    @objc private func toggleLocked(_ sender: NSButton) {
        if sender.state == .mixed { sender.state = .on }
        setFlag(\.isUserImmutable, sender.state == .on)
    }

    @objc private func toggleHidden(_ sender: NSButton) {
        if sender.state == .mixed { sender.state = .on }
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

    @objc private func closeWindow(_ sender: Any?) {
        window?.makeFirstResponder(nil)  // commit a tag being typed
        window?.close()
    }

    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        applyTags()
        cancelled = true
        Self.open.removeAll { $0 === self }
    }
}

extension Notification.Name {
    /// Tags or file flags changed outside a directory write (extended attributes don't touch the folder).
    static let fileTagsChanged = Notification.Name("WinExFileTagsChanged")
}

private extension NSBox {
    static func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
