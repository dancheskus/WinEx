import AppKit

/// What the keys do "как в Finder" and "как в Windows", side by side: the chosen mode's column is
/// lit up (the highlight slides over on a switch), keys that don't work in it fade out and a key
/// that means something else is struck through. A click on a column header switches the mode.
final class KeyboardModesView: NSView {
    struct Row {
        let action: String
        let finder: [String]
        let windows: [String]
        /// Only in Finder mode (with Windows keys the same key does something else).
        var finderOnly = false
    }

    static var allRows: [Row] {
        [
            Row(action: L("Открыть"), finder: ["⌘↓", "⌘O"], windows: ["Enter"]),
            Row(action: L("Переименовать"), finder: ["Enter"], windows: ["F2"], finderOnly: true),
            Row(action: L("На уровень выше"), finder: ["⌘↑"], windows: ["Backspace", "⌥↑"]),
            Row(action: L("Назад / вперёд"), finder: ["⌘[", "⌘]"], windows: ["⌥←", "⌥→"]),
            Row(action: L("Поиск"), finder: ["⌘F"], windows: ["F3"]),
            Row(action: L("Адресная строка"), finder: ["⌘L"], windows: ["F4", "⌥D"]),
            Row(action: L("Обновить"), finder: ["⌘R"], windows: ["F5"]),
            Row(action: L("Полный экран"), finder: ["⌃⌘F"], windows: ["F11"]),
            Row(action: L("В Корзину"), finder: ["⌘⌫"], windows: ["⌦ Delete"]),
            Row(action: L("Удалить навсегда"), finder: [], windows: ["⇧⌦"]),
            Row(action: L("Контекстное меню"), finder: [], windows: ["⇧F10"]),
        ]
    }

    /// The few that differ most, for the setup wizard.
    static var shortRows: [Row] { allRows.filter { [L("Открыть"), L("Переименовать"), L("На уровень выше"), L("В Корзину")].contains($0.action) } }

    var windowsKeys: Bool { didSet { if windowsKeys != oldValue { update(animated: true) } } }
    var onChange: ((Bool) -> Void)?

    private let grid = NSGridView()
    private let highlight = CALayer()
    private let finderHeader: ColumnHeader
    private let windowsHeader: ColumnHeader
    private var finderCaps: [(cap: KeyCap, finderOnly: Bool)] = []
    private var windowsCaps: [KeyCap] = []

    init(rows: [Row], windowsKeys: Bool) {
        self.windowsKeys = windowsKeys
        finderHeader = ColumnHeader(symbol: "apple.logo", title: L("Как в Finder"))
        windowsHeader = ColumnHeader(symbol: "pc", title: L("Как в Windows"))
        super.init(frame: .zero)
        wantsLayer = true
        highlight.cornerRadius = 10
        highlight.borderWidth = 1.5
        layer?.addSublayer(highlight)

        finderHeader.onClick = { [weak self] in self?.choose(false) }
        windowsHeader.onClick = { [weak self] in self?.choose(true) }
        grid.rowSpacing = 7
        grid.columnSpacing = 18
        grid.addRow(with: [NSGridCell.emptyContentView, finderHeader, windowsHeader])
        for row in rows {
            let action = NSTextField(labelWithString: row.action)
            action.textColor = .secondaryLabelColor
            let finder = caps(row.finder)
            finderCaps += finder.caps.map { ($0, row.finderOnly) }
            let windows = caps(row.windows)
            windowsCaps += windows.caps
            grid.addRow(with: [action, finder.view, windows.view]).rowAlignment = .firstBaseline
        }
        grid.row(at: 0).bottomPadding = 4
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .center
        grid.column(at: 2).xPlacement = .center
        grid.column(at: 1).width = 150
        grid.column(at: 2).width = 150
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        update(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func caps(_ keys: [String]) -> (view: NSView, caps: [KeyCap]) {
        guard !keys.isEmpty else {
            let none = NSTextField(labelWithString: "—")
            none.textColor = .quaternaryLabelColor
            return (none, [])
        }
        let caps = keys.map(KeyCap.init)
        let stack = NSStackView(views: caps)
        stack.spacing = 4
        return (stack, caps)
    }

    private func choose(_ windows: Bool) {
        guard windows != windowsKeys else { return }
        windowsKeys = windows
        onChange?(windows)
    }

    override func layout() {
        super.layout()
        placeHighlight()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(animated: false)
    }

    /// The lit column: from its header down to the last row.
    private func placeHighlight() {
        grid.layoutSubtreeIfNeeded()
        let column = windowsKeys ? 2 : 1
        var rect = NSRect.null
        for row in 0..<grid.numberOfRows {
            guard let view = grid.cell(atColumnIndex: column, rowIndex: row).contentView else { continue }
            rect = rect.union(view.convert(view.bounds, to: self))
        }
        let width = grid.column(at: column).width
        guard !rect.isNull else { return }
        highlight.frame = NSRect(x: rect.midX - width / 2 - 6, y: rect.minY - 8, width: width + 12, height: rect.height + 16)
    }

    private func update(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            highlight.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        }
        placeHighlight()
        CATransaction.commit()
        finderHeader.isChosen = !windowsKeys
        windowsHeader.isChosen = windowsKeys
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.25 : 0
            // ⌘-shortcuts from the menus work in both modes; Enter-to-rename only in Finder's
            for (cap, finderOnly) in finderCaps { cap.state = finderOnly && windowsKeys ? .struck : .on }
            for cap in windowsCaps { cap.state = windowsKeys ? .on : .off }
        }
    }
}

/// A key as a small key cap.
private final class KeyCap: NSView {
    enum State { case on, off, struck }
    var state: State = .on { didSet { refresh() } }
    private let label: NSTextField

    init(_ key: String) {
        label = NSTextField(labelWithString: key)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var firstBaselineOffsetFromTop: CGFloat { label.firstBaselineOffsetFromTop + 2 }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(state == .on ? 0.08 : 0.03).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(state == .on ? 0.18 : 0.08).cgColor
    }

    private func refresh() {
        animator().alphaValue = state == .on ? 1 : 0.45
        let text = label.stringValue
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: label.font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: state == .on ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .strikethroughStyle: state == .struck ? NSUnderlineStyle.single.rawValue : 0,
        ])
        toolTip = state == .struck ? L("С клавишами Windows Enter открывает") : nil
        needsDisplay = true
    }
}

/// "Как в Finder" / "Как в Windows" over a column: a click picks that mode.
private final class ColumnHeader: NSView {
    var onClick: (() -> Void)?
    var isChosen = false {
        didSet {
            title.textColor = isChosen ? .controlAccentColor : .secondaryLabelColor
            icon.contentTintColor = isChosen ? .controlAccentColor : .secondaryLabelColor
        }
    }
    private let title: NSTextField
    private let icon = NSImageView()

    init(symbol: String, title text: String) {
        title = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        let stack = NSStackView(views: [icon, title])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
