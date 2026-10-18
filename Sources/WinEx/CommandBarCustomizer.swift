import AppKit

/// «Настроить панель команд…», as Finder's «Настроить панель инструментов…»: every command (and a
/// divider) to drag onto the bar, the default set to drag as a whole. Not a sheet — a sheet would
/// cover the bar being arranged; a panel of the window, under the bar.
final class CommandBarCustomizer: NSPanel, NSWindowDelegate {
    private var onClose: (() -> Void)?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = L("Настроить панель команд")
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        delegate = self

        let intro = NSTextField(labelWithString: L("Перетащите нужные команды на панель команд."))
        intro.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        let palette = BarCommand.allCases.map { PaletteItem(item: $0.rawValue) } + [PaletteItem(item: CommandBarConfig.divider)]
        let columns = 7
        for row in stride(from: 0, to: palette.count, by: columns) {
            let views: [NSView] = Array(palette[row..<min(row + columns, palette.count)])
            grid.addRow(with: views + Array(repeating: NSGridCell.emptyContentView, count: columns - views.count))
        }

        let defaultsLabel = NSTextField(labelWithString: L("…или перетащите на панель набор по умолчанию:"))
        let defaultSet = DefaultSetView()
        let hint = SettingsForm.hint(L("Чтобы убрать команду, перетащите её с панели. Порядок команд меняется и без этого окна — перетаскиванием с нажатой ⌘."))

        let done = NSButton(title: L("Готово"), target: self, action: #selector(finish(_:)))
        done.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([done], in: .trailing)

        let stack = NSStackView(views: [intro, grid, defaultsLabel, defaultSet, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: grid)
        stack.setCustomSpacing(6, after: defaultsLabel)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        // The grid keeps its own width (the default set is wider): no gap between its columns
        grid.setContentHuggingPriority(.required, for: .horizontal)
        hint.preferredMaxLayoutWidth = 640
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        contentView = content
        setContentSize(content.fittingSize)
    }

    /// Shown under `bar`, in the middle of its window, which it stays with.
    func show(under bar: NSView) {
        guard let parent = bar.window else { return }
        let barBottom = parent.convertToScreen(bar.convert(bar.bounds, to: nil)).minY
        setFrameTopLeftPoint(NSPoint(x: parent.frame.midX - frame.width / 2, y: barBottom - 12))
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
    }

    @objc private func finish(_ sender: Any?) { close() }

    override func cancelOperation(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        parent?.removeChildWindow(self)
        onClose?()
        onClose = nil
    }
}

/// A command in the set to choose from: its icon and name; dragged, it looks as on the bar.
private final class PaletteItem: NSView, NSDraggingSource {
    let item: String

    init(item: String) {
        self.item = item
        super.init(frame: .zero)
        let command = BarCommand(rawValue: item)
        let icon = NSImageView(image: command.flatMap { SidebarConfig.icon($0.symbol, pointSize: 18) } ?? PaletteItem.dividerImage)
        icon.contentTintColor = .labelColor
        let label = NSTextField(wrappingLabelWithString: command?.title ?? L("Разделитель"))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 104
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 108),
            heightAnchor.constraint(equalToConstant: 66),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        toolTip = command?.tip
        setAccessibilityRole(.button)
        setAccessibilityLabel(command?.title ?? L("Разделитель"))
    }

    required init?(coder: NSCoder) { fatalError() }

    private static var dividerImage: NSImage {
        NSImage(size: NSSize(width: 18, height: 22), flipped: false) { rect in
            NSColor.separatorColor.setFill()
            NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
            return true
        }
    }

    /// The whole item takes the press (not the icon or the label).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDragged(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item, forType: .barCommand)
        let dragged = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // How it will look on the bar
        let look: NSView
        if let command = BarCommand(rawValue: item) {
            look = CommandButton(symbol: command.symbol, title: command.isMenu ? command.title : nil, tip: command.tip, menu: command.isMenu)
        } else {
            look = NSImageView(image: PaletteItem.dividerImage)
        }
        look.setFrameSize(look.fittingSize.width > 0 ? look.fittingSize : NSSize(width: 18, height: 22))
        let point = convert(event.locationInWindow, from: nil)
        dragged.setDraggingFrame(NSRect(x: point.x - look.frame.width / 2, y: point.y - look.frame.height / 2,
                                        width: look.frame.width, height: look.frame.height),
                                 contents: CommandBar.snapshot(look))
        beginDraggingSession(with: [dragged], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}

/// The default set as a strip, dragged onto the bar as a whole.
private final class DefaultSetView: NSView, NSDraggingSource {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        let views: [NSView] = CommandBarConfig.defaultItems.map { item in
            guard let command = BarCommand(rawValue: item) else {
                let line = NSBox()
                line.boxType = .separator
                line.heightAnchor.constraint(equalToConstant: 22).isActive = true
                return line
            }
            let button = CommandButton(symbol: command.symbol, title: command.isMenu ? command.title : nil, tip: command.tip, menu: command.isMenu)
            button.isEditing = true
            return button
        }
        let stack = NSStackView(views: views)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = L("Набор по умолчанию")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDragged(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(CommandBar.defaultSet, forType: .barCommand)
        let dragged = NSDraggingItem(pasteboardWriter: pasteboardItem)
        dragged.setDraggingFrame(bounds, contents: CommandBar.snapshot(self))
        beginDraggingSession(with: [dragged], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}
