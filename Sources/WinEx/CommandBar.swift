import AppKit

/// Explorer's command bar under the address row: "Создать", the clipboard and file commands,
/// "Сортировать", "Просмотреть" and "…" with the rest.
final class CommandBar: NSView {
    static let height: CGFloat = 44

    /// Menus are built when they open (they show the current state).
    var newItemMenu: (() -> NSMenu?)?
    var sortMenu: (() -> NSMenu?)?
    var viewMenu: (() -> NSMenu?)?
    var moreMenu: (() -> NSMenu?)?
    /// Scenario hook: "new", "sort", "view", "more" as each menu opens.
    var onMenuOpen: ((String) -> Void)?

    let newButton = CommandButton(symbol: "plus.circle", title: "Создать", tip: "Создать папку или документ", menu: true)
    let cutButton = CommandButton(symbol: "scissors", tip: "Вырезать (⌘X)")
    let copyButton = CommandButton(symbol: "doc.on.doc", tip: "Копировать (⌘C)")
    let pasteButton = CommandButton(symbol: "doc.on.clipboard", tip: "Вставить (⌘V)")
    let renameButton = CommandButton(symbol: "character.cursor.ibeam", tip: "Переименовать")
    let shareButton = CommandButton(symbol: "square.and.arrow.up", tip: "Поделиться")
    let deleteButton = CommandButton(symbol: "trash", tip: "Удалить (⌘⌫)")
    let sortButton = CommandButton(symbol: "arrow.up.arrow.down", title: "Сортировать", tip: "Порядок файлов", menu: true)
    let viewButton = CommandButton(symbol: "square.grid.2x2", title: "Просмотреть", tip: "Вид", menu: true)
    let moreButton = CommandButton(symbol: "ellipsis", tip: "Другие команды")

    override init(frame: NSRect) {
        super.init(frame: frame)
        newButton.onClick = { [weak self] in self?.pop(self?.newItemMenu, under: self?.newButton) }
        sortButton.onClick = { [weak self] in self?.pop(self?.sortMenu, under: self?.sortButton) }
        viewButton.onClick = { [weak self] in self?.pop(self?.viewMenu, under: self?.viewButton) }
        moreButton.onClick = { [weak self] in self?.pop(self?.moreMenu, under: self?.moreButton) }

        let stack = NSStackView(views: [
            newButton, Self.divider(),
            cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton, Self.divider(),
            sortButton, viewButton, Self.divider(), moreButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        // Too narrow a window: the bar is cut on the right rather than squeezing the buttons
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

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

    private func pop(_ provider: (() -> NSMenu?)?, under button: CommandButton?) {
        guard let button, let menu = provider?() else { return }
        MenuStyle.decorate(menu)
        onMenuOpen?([newButton: "new", sortButton: "sort", viewButton: "view", moreButton: "more"][button] ?? "?")
        button.isOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
        button.isOpen = false
        // Closed by a click on another command (Explorer: that command works at once — its menu
        // opens). The click itself only ended the menu; pass it on. (Its press or, by the time the
        // menu has let go, its release; a release on a menu item belongs to the menu's window.)
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp, event.window === window,
           let other = commandButtons.first(where: { $0 !== button && $0.isEnabled
                && $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }) {
            DispatchQueue.main.async { other.perform() }
        }
    }

    private var commandButtons: [CommandButton] {
        [newButton, cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton, sortButton, viewButton, moreButton]
    }
}

/// A flat command: an icon (and a title, and "⌄" for a menu), a rounded highlight under the mouse.
final class CommandButton: NSView {
    var onClick: (() -> Void)?
    /// Sent like a button's action (to the first responder when `target` is nil).
    var action: Selector?
    weak var target: AnyObject?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.35; needsDisplay = true } }
    var isOpen = false { didSet { needsDisplay = true } }

    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String? = nil, tip: String, menu: Bool = false) {
        super.init(frame: .zero)
        toolTip = tip
        setAccessibilityRole(.button)
        setAccessibilityLabel(title ?? tip)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage())
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
    }

    required init?(coder: NSCoder) { fatalError() }

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
        guard isEnabled, hovering || pressed || isOpen else { return }
        NSColor.labelColor.withAlphaComponent(pressed || isOpen ? 0.14 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}
