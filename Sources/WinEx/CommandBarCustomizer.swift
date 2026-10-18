import AppKit

/// «Настроить панель команд…», as Finder's «Настроить панель инструментов…»: the commands not on
/// the bar yet (and a divider), each as it looks there, to drag onto it; the default set to drag
/// as a whole. Not a sheet — a sheet would cover the bar being arranged; a panel of the window,
/// under the bar. «Отменить» (or Esc) puts the bar back as it was.
final class CommandBarCustomizer: NSPanel, NSWindowDelegate {
    private var onClose: (() -> Void)?
    /// The bar as it was when the panel opened («Отменить»).
    private let original = CommandBarConfig.items
    private let palette: PaletteFlow
    private let observers = Observers()

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let defaultSet = DefaultSetView()
        palette = PaletteFlow(width: max(defaultSet.fittingSize.width, 640))
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = L("Настроить панель команд")
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        delegate = self

        let intro = NSTextField(labelWithString: L("Перетащите нужные команды на панель команд."))
        intro.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let defaultsLabel = NSTextField(labelWithString: L("…или перетащите на панель набор по умолчанию:"))
        let hint = SettingsForm.hint(L("Чтобы убрать команду, перетащите её с панели. Порядок команд меняется и без этого окна — перетаскиванием с нажатой ⌘."))

        let cancel = NSButton(title: L("Отменить"), target: self, action: #selector(cancel(_:)))
        let done = NSButton(title: L("Готово"), target: self, action: #selector(finish(_:)))
        done.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([cancel, done], in: .trailing)

        let stack = NSStackView(views: [intro, palette, defaultsLabel, defaultSet, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: palette)
        stack.setCustomSpacing(6, after: defaultsLabel)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
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
        // A command put on the bar leaves the set, one taken off comes back
        observers.add(CommandBarConfig.didChange) { [weak self] in self?.palette.update() }
    }

    /// Shown under `bar`, in the middle of its window, which it stays with.
    func show(under bar: NSView) {
        guard let parent = bar.window else { return }
        let barBottom = parent.convertToScreen(bar.convert(bar.bounds, to: nil)).minY
        setFrameTopLeftPoint(NSPoint(x: parent.frame.midX - frame.width / 2, y: barBottom - 12))
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
    }

    /// What the set offers now (scenarios).
    var offered: [String] { palette.subviews.compactMap { ($0 as? PaletteItem)?.item } }

    @objc private func finish(_ sender: Any?) { close() }

    @objc private func cancel(_ sender: Any?) {
        if CommandBarConfig.items != original { CommandBarConfig.items = original }
        close()
    }

    override func cancelOperation(_ sender: Any?) { cancel(sender) }

    func windowWillClose(_ notification: Notification) {
        parent?.removeChildWindow(self)
        onClose?()
        onClose = nil
    }
}

/// The set to choose from: the commands not on the bar and a divider, in rows as wide as the
/// default set. Its height is the one for every command, so it doesn't jump as commands go.
private final class PaletteFlow: NSView {
    private let width: CGFloat
    private let items = BarCommand.allCases.map { PaletteItem(item: $0.rawValue) } + [PaletteItem(item: CommandBarConfig.divider)]
    private static let spacing: CGFloat = 4

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let height = Self.place(items, width: width)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update() {
        let onBar = Set(CommandBarConfig.items).subtracting([CommandBarConfig.divider])
        let shown = items.filter { !onBar.contains($0.item) }
        subviews = shown
        _ = Self.place(shown, width: width)
    }

    /// Lays the items out left to right, wrapping; returns the height they take.
    @discardableResult
    private static func place(_ items: [PaletteItem], width: CGFloat) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for item in items {
            let size = item.size
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            item.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }
}

/// A command in the set to choose from, as it looks on the bar (a pull-down at its full width),
/// an icon's name under it. Dragged at the first click, even while the panel isn't active.
private final class PaletteItem: NSView, NSDraggingSource {
    let item: String
    /// What goes on the bar: the command's button, or a divider.
    private let look: NSView

    init(item: String) {
        self.item = item
        let command = BarCommand(rawValue: item)
        if let command {
            let button = CommandButton(symbol: command.symbol, title: command.isMenu ? command.title : nil, tip: command.tip, menu: command.isMenu)
            button.isEditing = true
            look = button
        } else {
            look = PaletteItem.divider()
        }
        super.init(frame: .zero)
        look.translatesAutoresizingMaskIntoConstraints = false
        addSubview(look)
        NSLayoutConstraint.activate([
            look.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            look.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        // Under an icon its name; a pull-down shows its own
        if command?.isMenu != true {
            let label = NSTextField(wrappingLabelWithString: command?.title ?? L("Разделитель"))
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.maximumNumberOfLines = 2
            label.preferredMaxLayoutWidth = 104
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor, constant: 38),
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 104),
            ])
        }
        toolTip = command?.tip
        setAccessibilityRole(.button)
        setAccessibilityLabel(command?.title ?? L("Разделитель"))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Icons get room for their names; a pull-down is as wide as on the bar.
    var size: NSSize {
        NSSize(width: max(108, look.fittingSize.width + 8), height: 70)
    }

    private static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 13),
            holder.heightAnchor.constraint(equalToConstant: 32),
            line.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 22),
        ])
        return holder
    }

    /// The whole item takes the press (not the button or the label).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item, forType: .barCommand)
        let dragged = NSDraggingItem(pasteboardWriter: pasteboardItem)
        dragged.setDraggingFrame(convert(look.bounds, from: look), contents: CommandBar.snapshot(look))
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

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
