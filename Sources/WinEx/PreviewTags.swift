import AppKit

/// The preview pane's «Теги», as in Finder: the file's tags as coloured plates and «Добавить тег»
/// after them, in rows that wrap. A plate is clicked to take its tag off; «Добавить тег» opens
/// `TagPicker`.
final class TagStrip: NSView {
    /// The file's tags, in their order.
    var tags: [FileTags.Tag] = [] { didSet { rebuild() } }
    var onAdd: ((FileTags.Tag) -> Void)?
    var onRemove: ((FileTags.Tag) -> Void)?

    private var plates: [TagPlate] = []
    private let addButton = NSButton(title: L("Добавить тег"), target: nil, action: nil)
    private var picker: NSPopover?
    private static let inset = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
    private static let gap: CGFloat = 6

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 12)
        addButton.contentTintColor = .linkColor
        addButton.target = self
        addButton.action = #selector(showPicker(_:))
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }

    private func rebuild() {
        plates.forEach { $0.removeFromSuperview() }
        plates = tags.map { tag in
            let plate = TagPlate(tag: tag)
            plate.onClick = { [weak self] plate in self?.offerRemoval(of: tag, from: plate) }
            addSubview(plate)
            return plate
        }
        needsLayout = true
    }

    /// The plates and the button laid out in rows of `width`; returns the height they take.
    @discardableResult
    func arrange(width: CGFloat, apply: Bool = true) -> CGFloat {
        let inset = Self.inset
        var x = inset.left, y = inset.top, rowHeight: CGFloat = 0
        let views: [NSView] = plates + [addButton]
        for view in views {
            let size = view === addButton ? NSSize(width: ceil(addButton.fittingSize.width), height: 20) : view.fittingSize
            if x > inset.left, x + size.width > width - inset.right {
                x = inset.left
                y += rowHeight + 4
                rowHeight = 0
            }
            if apply { view.frame = NSRect(x: x, y: y, width: min(size.width, width - inset.left - inset.right), height: size.height) }
            x += size.width + Self.gap
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight + inset.bottom
    }

    override func layout() {
        super.layout()
        arrange(width: bounds.width)
    }

    private func offerRemoval(of tag: FileTags.Tag, from plate: NSView) {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: L("Удалить тег «%@»", tag.name), action: #selector(removeTag(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = tag.name
        item.image = MenuStyle.symbol("minus.circle")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: plate.bounds.maxY + 4), in: plate)
    }

    @objc private func removeTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let tag = tags.first(where: { $0.name == name }) else { return }
        onRemove?(tag)
    }

    @objc private func showPicker(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        let picker = TagPicker(excluding: Set(tags.map(\.name))) { [weak self, weak popover] tag in
            popover?.performClose(nil)
            self?.onAdd?(tag)
        }
        popover.contentViewController = picker
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        self.picker = popover
    }

    #if DEBUG
    var debugPlates: [String] { plates.map { "\($0.fileTag.name)/\($0.fileTag.color)" } }
    func debugPicker() -> TagPicker? {
        showPicker(addButton)
        return picker?.contentViewController as? TagPicker
    }
    func debugClosePicker() { picker?.close() }
    #endif
}

/// One tag: its name on its colour, rounded (grey for a tag without a colour).
private final class TagPlate: NSView {
    let fileTag: FileTags.Tag
    var onClick: ((TagPlate) -> Void)?
    private let label: NSTextField

    init(tag: FileTags.Tag) {
        fileTag = tag
        label = NSTextField(labelWithString: tag.name)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        toolTip = tag.name
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let text = label.fittingSize
        return NSSize(width: ceil(text.width) + 12, height: 20)
    }

    override func layout() {
        super.layout()
        let text = label.fittingSize
        label.frame = NSRect(x: 6, y: (bounds.height - text.height) / 2, width: bounds.width - 12, height: text.height)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (FileTags.color(forIndex: fileTag.color) ?? .systemGray).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?(self) }
    override func rightMouseDown(with event: NSEvent) { onClick?(self) }
}

/// Finder's tag picker: a field to type a tag (a new one too), the favourite tags with their
/// colours under it and «Показать все…» for the rest. Typing narrows the list; Return takes the
/// typed name (a known tag keeps its colour).
final class TagPicker: NSViewController, NSTextFieldDelegate {
    private let excluded: Set<String>
    private let onPick: (FileTags.Tag) -> Void
    private let field = NSTextField()
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var showsAll = false
    private static let width: CGFloat = 230
    private static let rowHeight: CGFloat = 24

    init(excluding excluded: Set<String>, onPick: @escaping (FileTags.Tag) -> Void) {
        self.excluded = excluded
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Favourites first (Finder's order), then every other tag known.
    private var known: [FileTags.Tag] {
        var seen = Set<String>()
        let all = FileTags.favorites + TagLibrary.entries.map { FileTags.Tag(name: $0.name, color: $0.color) }
        return all.filter { seen.insert($0.name).inserted && !excluded.contains($0.name) }
    }

    override func loadView() {
        let root = NSView()
        field.placeholderString = L("Добавить тег")
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        let document = FlippedView()
        document.addSubview(list)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        for view in [field, scroll, list] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(field)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.widthAnchor.constraint(equalToConstant: Self.width - 8),
        ])
        view = root
        reloadList()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    private func reloadList() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        var rows: [NSView] = []
        if typed.isEmpty {
            let favorites = Set(FileTags.favorites.map(\.name))
            let tags = known
            let shown = showsAll ? tags : tags.filter { favorites.contains($0.name) }
            rows = shown.map(row)
            if !showsAll, shown.count < tags.count {
                rows.append(PickerRow(title: L("Показать все…"), image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)) { [weak self] in
                    self?.showsAll = true
                    self?.reloadList()
                })
            }
        } else {
            let matches = known.filter { $0.name.localizedCaseInsensitiveContains(typed) }
            rows = matches.map(row)
            // A name not known yet: a new tag (no colour)
            if !known.contains(where: { $0.name.compare(typed, options: .caseInsensitive) == .orderedSame }) && !excluded.contains(typed) {
                rows.append(PickerRow(title: L("Создать тег «%@»", typed), image: NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)) { [weak self] in
                    self?.onPick(FileTags.Tag(name: typed, color: 0))
                })
            }
        }
        rows.forEach(list.addArrangedSubview)
        for row in rows { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        let height = CGFloat(rows.count) * Self.rowHeight
        list.layoutSubtreeIfNeeded()
        scroll.documentView?.frame = NSRect(x: 0, y: 0, width: Self.width - 8, height: height)
        preferredContentSize = NSSize(width: Self.width, height: 10 + 24 + 6 + min(max(height, Self.rowHeight), 9 * Self.rowHeight) + 6)
    }

    private func row(_ tag: FileTags.Tag) -> NSView {
        PickerRow(title: tag.name, image: FileTags.dotImage(color: tag.color, size: 12)) { [weak self] in self?.onPick(tag) }
    }

    func controlTextDidChange(_ obj: Notification) { reloadList() }

    /// Return: the typed tag (known: with its colour).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        pickTyped()
        return true
    }

    private func pickTyped() {
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !excluded.contains(typed) else { return }
        onPick(known.first { $0.name.compare(typed, options: .caseInsensitive) == .orderedSame } ?? FileTags.Tag(name: typed, color: 0))
    }

    #if DEBUG
    var debugRows: [String] { list.arrangedSubviews.compactMap { ($0 as? PickerRow)?.title } }
    func debugType(_ text: String) { field.stringValue = text; reloadList() }
    func debugReturn() { pickTyped() }
    func debugClick(_ title: String) { list.arrangedSubviews.compactMap { $0 as? PickerRow }.first { $0.title == title }?.action() }
    #endif
}

/// A row of the picker: a dot (or symbol) and a name, highlighted under the mouse like a menu item.
private final class PickerRow: NSView {
    let title: String
    let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, image: NSImage?, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        super.init(frame: .zero)
        let icon = NSImageView(image: image ?? NSImage())
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { action() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
