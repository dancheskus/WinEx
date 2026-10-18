import AppKit

extension NSPasteboard.PasteboardType {
    /// A command dragged onto the command bar or within it (`CommandBarConfig`'s item string).
    static let barCommand = NSPasteboard.PasteboardType("dev.winex.bar-command")
}

/// Explorer's command bar under the address row: "Создать", the clipboard and file commands,
/// "Сортировать", "Группировать", "Просмотреть" and "…" with the rest — or what the user put there
/// (`CommandBarConfig`). Commands that don't fit a narrow window go into "…" (from the right), as
/// in Explorer.
final class CommandBar: NSView, NSDraggingSource {
    static let height: CGFloat = 44
    /// The default set, dragged as a whole from «Настроить панель команд…».
    static let defaultSet = "set:default"

    /// A pull-down's menu, built when it opens (it shows the current state).
    var menuProvider: ((BarCommand) -> NSMenu?)?
    /// "…"'s own commands.
    var moreMenu: (() -> NSMenu?)?
    /// Where a command's action goes (a nil target: the responder chain).
    var actionProvider: ((BarCommand) -> (action: Selector, target: AnyObject?)?)? { didSet { rebuild() } }
    /// Whether a command can act now, and whether a switch (hidden files) is on.
    var enabledProvider: ((BarCommand) -> Bool)?
    var stateProvider: ((BarCommand) -> Bool)?
    /// The bar's context menu: «Настроить панель команд…», «Скрыть панель команд».
    var onCustomize: (() -> Void)?
    var onHide: (() -> Void)?
    /// Scenario hook: "new", "sort", "group", "view", "more" as each menu opens.
    var onMenuOpen: ((String) -> Void)?

    let moreButton = CommandButton(symbol: "ellipsis", tip: L("Другие команды"))
    /// The commands on the bar.
    private(set) var buttons: [BarCommand: CommandButton] = [:]

    /// Being arranged («Настроить панель команд…»): commands are dragged, not clicked; every one
    /// and every divider shows.
    var isEditing = false {
        didSet {
            buttons.values.forEach { $0.isEditing = isEditing }
            if !isEditing { insertionMark.isHidden = true }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        moreButton.onClick = { [weak self] in self?.pop(self?.moreMenuWithOverflow, under: self?.moreButton, name: "more") }

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        // (Too narrow a window: commands go into "…", see `layout`; never squeezed)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        insertionMark.wantsLayer = true
        insertionMark.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionMark.layer?.cornerRadius = 1
        insertionMark.isHidden = true
        addSubview(stack)
        addSubview(line)
        addSubview(insertionMark)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        clipsToBounds = true
        registerForDraggedTypes([.barCommand])
        observers.add(CommandBarConfig.didChange) { [weak self] in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    private let stack = NSStackView()
    private let moreDivider = CommandBar.divider()
    private let insertionMark = NSView()
    private let observers = Observers()
    /// `CommandBarConfig.items` and their views, in order.
    private var items: [String] = []
    private var itemViews: [NSView] = []

    /// Builds the bar from the settings (buttons kept, so their state and hover survive).
    private func rebuild() {
        items = CommandBarConfig.items
        let old = buttons
        buttons = [:]
        itemViews = items.map { item in
            guard let command = BarCommand(rawValue: item) else { return CommandBar.divider() }
            let button = old[command] ?? makeButton(command)
            // (Kept buttons too: the actions may have come after them)
            if !command.isMenu, let (action, target) = actionProvider?(command) {
                button.action = action
                button.target = target
            }
            buttons[command] = button
            return button
        }
        stack.setViews(itemViews + [moreDivider, moreButton], in: .leading)
        updateState()
        needsLayout = true
    }

    private func makeButton(_ command: BarCommand) -> CommandButton {
        let button = CommandButton(symbol: command.symbol, title: command.isMenu ? command.title : nil, tip: command.tip,
                                   menu: command.isMenu, menuTitle: command.title)
        button.command = command
        button.isEditing = isEditing
        if command.isMenu {
            button.onClick = { [weak self, weak button] in
                self?.pop({ self?.menuProvider?(command) }, under: button, name: command.rawValue)
            }
        }
        return button
    }

    /// What the commands can act on right now.
    func updateState() {
        for (command, button) in buttons {
            button.isEnabled = enabledProvider?(command) ?? true
            button.isOn = stateProvider?(command) ?? false
        }
    }

    // MARK: - Overflow

    /// Commands that don't fit, in the bar's order: they head the "…" menu.
    private(set) var overflow: [CommandButton] = []

    override func layout() {
        super.layout()
        updateOverflow()
    }

    /// Hides what doesn't fit, from the right (widths from each command's own size, so hiding
    /// doesn't change the answer and the layout settles at once). A divider shows only between
    /// commands that show.
    private func updateOverflow() {
        let available = bounds.width - 20
        guard available > 0 else { return }
        var dropped = Set<ObjectIdentifier>()
        func shownViews() -> [NSView] {
            if isEditing { return itemViews + [moreDivider, moreButton] }
            var shown: [NSView] = []
            var divider: NSView?
            for view in itemViews {
                if view is CommandButton {
                    guard !dropped.contains(ObjectIdentifier(view)) else { continue }
                    if let divider { shown.append(divider) }
                    divider = nil
                    shown.append(view)
                } else if !shown.isEmpty {
                    divider = view
                }
            }
            return shown + (shown.isEmpty ? [] : [moreDivider]) + [moreButton]
        }
        func width(_ views: [NSView]) -> CGFloat {
            views.reduce(0) { $0 + $1.fittingSize.width } + stack.spacing * CGFloat(max(views.count - 1, 0))
        }
        if !isEditing {
            for button in itemViews.reversed() where button is CommandButton && width(shownViews()) > available {
                dropped.insert(ObjectIdentifier(button))
            }
        }
        let shown = Set(shownViews().map(ObjectIdentifier.init))
        for view in itemViews + [moreDivider] where view.isHidden == shown.contains(ObjectIdentifier(view)) {
            view.isHidden = !shown.contains(ObjectIdentifier(view))
        }
        overflow = itemViews.compactMap { $0 as? CommandButton }.filter { dropped.contains(ObjectIdentifier($0)) }
    }

    /// "…": the commands that didn't fit (their menus as submenus), then its own.
    func moreMenuWithOverflow() -> NSMenu? {
        let menu = moreMenu?() ?? NSMenu()
        guard !overflow.isEmpty else { return menu }
        menu.autoenablesItems = false
        for (index, button) in overflow.enumerated() {
            let item = NSMenuItem(title: button.menuTitle, action: nil, keyEquivalent: "")
            item.image = SidebarConfig.icon(button.symbol, pointSize: 14)
            item.isEnabled = button.isEnabled
            item.state = button.isOn ? .on : .off
            if let command = button.command, command.isMenu {
                item.submenu = menuProvider?(command)
            } else {
                item.action = #selector(performOverflow(_:))
                item.target = self
                item.representedObject = button
            }
            menu.insertItem(item, at: index)
        }
        if menu.items.count > overflow.count { menu.insertItem(.separator(), at: overflow.count) }
        return menu
    }

    @objc private func performOverflow(_ sender: NSMenuItem) {
        (sender.representedObject as? CommandButton)?.perform()
    }

    private static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 13),
            holder.heightAnchor.constraint(equalToConstant: 22),
            line.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
        return holder
    }

    private func pop(_ provider: (() -> NSMenu?)?, under button: CommandButton?, name: String) {
        guard let button, let menu = provider?() else { return }
        MenuStyle.decorate(menu)
        onMenuOpen?(name)
        button.isOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
        button.isOpen = false
        // Closed by a click on another command (Explorer: that command works at once — its menu
        // opens). The click itself only ended the menu; pass it on. (Its press or, by the time the
        // menu has let go, its release; a release on a menu item belongs to the menu's window.)
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp, event.window === window,
           let other = commandButtons.first(where: { $0 !== button && $0.isEnabled && !$0.isHidden
                && $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }) {
            DispatchQueue.main.async { other.perform() }
        }
    }

    private var commandButtons: [CommandButton] {
        itemViews.compactMap { $0 as? CommandButton } + [moreButton]
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isEditing else { return nil }
        let menu = NSMenu()
        if let index = itemIndex(at: convert(event.locationInWindow, from: nil)), let command = BarCommand(rawValue: items[index]) {
            let remove = menu.addItem(withTitle: L("Убрать «%@» с панели", command.title), action: #selector(removeItem(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = index
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: L("Настроить панель команд…"), action: #selector(customize(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Скрыть панель команд"), action: #selector(hide(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func removeItem(_ sender: NSMenuItem) {
        CommandBarConfig.items = CommandBarConfig.removing(at: sender.tag, from: items)
    }

    @objc private func customize(_ sender: Any?) { onCustomize?() }
    @objc private func hide(_ sender: Any?) { onHide?() }

    // MARK: - Arranging by dragging

    /// The item under `point` (in the bar), if it shows.
    private func itemIndex(at point: NSPoint) -> Int? {
        itemViews.firstIndex { !$0.isHidden && convert($0.bounds, from: $0).contains(point) }
    }

    /// While arranging, or with ⌘ held (as in any Mac toolbar), a press on a command picks it up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, hit !== self else { return hit }
        let event = NSApp.currentEvent
        let commandDrag = event?.type == .leftMouseDown && event?.modifierFlags.contains(.command) == true
        guard isEditing || commandDrag, itemIndex(at: convert(point, from: superview)) != nil else { return hit }
        return self
    }

    /// While arranging, the panel of commands is the active window: the first click picks up.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEditing }

    override func mouseDown(with event: NSEvent) {
        guard let window, let index = itemIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        // A drag, not a click: picked up once the mouse moves a little
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard next.type == .leftMouseDragged else { return }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                return beginDrag(index, event: event)
            }
        }
    }

    /// The index (in `CommandBarConfig.items`) of the item being dragged off this bar.
    private(set) var draggedIndex: Int?

    private func beginDrag(_ index: Int, event: NSEvent) {
        let view = itemViews[index]
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(items[index], forType: .barCommand)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(convert(view.bounds, from: view), contents: CommandBar.snapshot(view))
        draggedIndex = index
        view.alphaValue = 0.25
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Dropped off the bar it goes away, as from a toolbar (no sliding back)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    /// A picture of an item (what is dragged).
    static func snapshot(_ view: NSView) -> NSImage {
        view.layoutSubtreeIfNeeded()
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// Off the bar, the cursor says the command will go.
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let window else { return }
        let onBar = window.convertToScreen(convert(bounds, to: nil)).contains(screenPoint)
        (onBar ? NSCursor.arrow : NSCursor.disappearingItem).set()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let index = draggedIndex
        draggedIndex = nil
        itemViews.forEach { $0.alphaValue = 1 }
        guard operation == [], let index else { return }
        NSCursor.arrow.set()
        CommandBarConfig.items = CommandBarConfig.removing(at: index, from: items)
    }

    /// Where a drop at `point` goes: before the first shown item to its right.
    private func insertionIndex(at point: NSPoint) -> Int {
        itemViews.indices.first { !itemViews[$0].isHidden && convert(itemViews[$0].bounds, from: itemViews[$0]).midX > point.x } ?? items.count
    }

    private func showInsertion(at index: Int) {
        let shown = itemViews.filter { !$0.isHidden }
        let x: CGFloat
        if index < itemViews.count {
            x = convert(itemViews[index].bounds, from: itemViews[index]).minX - stack.spacing / 2
        } else if let last = shown.last {
            x = convert(last.bounds, from: last).maxX + stack.spacing / 2
        } else {
            x = stack.frame.minX
        }
        insertionMark.frame = NSRect(x: x - 1, y: (bounds.height - 26) / 2, width: 2, height: 26)
        insertionMark.isHidden = false
    }

    /// Items come from the bar itself (⌘-drag or while arranging) or, while arranging, from the
    /// set to choose from.
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        isEditing || sender.draggingSource is CommandBar
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        showInsertion(at: insertionIndex(at: convert(sender.draggingLocation, from: nil)))
        return sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionMark.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertionMark.isHidden = true
        guard accepts(sender), let item = sender.draggingPasteboard.string(forType: .barCommand) else { return false }
        if item == CommandBar.defaultSet {
            CommandBarConfig.items = CommandBarConfig.defaultItems
        } else {
            let index = insertionIndex(at: convert(sender.draggingLocation, from: nil))
            CommandBarConfig.items = CommandBarConfig.dropping(item, from: (sender.draggingSource as? CommandBar)?.draggedIndex,
                                                               at: index, into: items)
        }
        return true
    }
}

/// A flat command: an icon (and a title, and "⌄" for a menu), a rounded highlight under the mouse.
final class CommandButton: NSView {
    var onClick: (() -> Void)?
    /// Sent like a button's action (to the first responder when `target` is nil).
    var action: Selector?
    weak var target: AnyObject?
    var isEnabled = true { didSet { updateLook() } }
    var isOpen = false { didSet { needsDisplay = true } }
    /// A switch that's on (hidden files shown): highlighted like an open menu.
    var isOn = false { didSet { needsDisplay = true } }
    /// The bar is being arranged: every command looks available, none lights up.
    var isEditing = false { didSet { updateLook() } }
    /// The command it is ("…" has none).
    var command: BarCommand?

    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    /// The icon, and what the command is called in the "…" menu (the title, or the explanation
    /// without its shortcut).
    let symbol: String
    let menuTitle: String

    init(symbol: String, title: String? = nil, tip: String, menu: Bool = false, menuTitle: String? = nil) {
        self.symbol = symbol
        self.menuTitle = menuTitle ?? title ?? tip.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression)
        super.init(frame: .zero)
        toolTip = tip
        setAccessibilityRole(.button)
        setAccessibilityLabel(title ?? tip)
        let icon = NSImageView(image: SidebarConfig.icon(symbol, pointSize: 15) ?? NSImage())
        icon.contentTintColor = .labelColor
        var views: [NSView] = [icon]
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13)
            views.append(label)
        }
        if menu {
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage())
            chevron.contentTintColor = .secondaryLabelColor
            views.append(chevron)
        }
        if views.count == 1 {
            // Just an icon: a fixed square with the icon in its middle
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageAlignment = .alignCenter
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.trailingAnchor.constraint(equalTo: trailingAnchor),
                icon.topAnchor.constraint(equalTo: topAnchor),
                icon.bottomAnchor.constraint(equalTo: bottomAnchor),
                widthAnchor.constraint(equalToConstant: 38),
                heightAnchor.constraint(equalToConstant: 32),
            ])
        } else {
            let stack = NSStackView(views: views)
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 20),
                heightAnchor.constraint(equalToConstant: 32),
            ])
        }
        setContentCompressionResistancePriority(.required, for: .horizontal)
        // The explanation shows under the mouse wherever it is on the button (the icon and the
        // title cover it: AppKit asks the view under the mouse)
        func share(_ view: NSView) { view.toolTip = tip; view.subviews.forEach(share) }
        subviews.forEach(share)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateLook() {
        alphaValue = isEnabled || isEditing ? 1 : 0.35
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // A menu opens on press, like a pull-down
        if onClick != nil, action == nil {
            hovering = false
            onClick?()
            return
        }
        pressed = true
    }

    /// What a click does: opens the menu or sends the action.
    func perform() {
        guard isEnabled else { return }
        if let action { NSApp.sendAction(action, to: target, from: self) } else { onClick?() }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let action { NSApp.sendAction(action, to: target, from: self) } else { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled, !isEditing, hovering || pressed || isOpen || isOn else { return }
        NSColor.labelColor.withAlphaComponent(pressed || isOpen || isOn ? 0.14 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}
