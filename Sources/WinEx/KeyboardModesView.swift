import AppKit

/// What the keys do "как в Finder" and "как в Windows", side by side: the chosen mode's column is
/// lit up (the highlight slides over on a switch), keys that don't work in it fade out and a key
/// that means something else is struck through. A click anywhere on a column switches the mode; the
/// other column lights up faintly under the mouse.
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
            Row(action: L("В Корзину"), finder: ["⌘⌫"], windows: ["⌦ Delete"]),
            Row(action: L("Удалить навсегда"), finder: ["⌥⌘⌫"], windows: ["⇧⌦"]),
            Row(action: L("Контекстное меню"), finder: [], windows: ["⇧F10"]),
        ]
    }

    /// The few that differ most, for the setup wizard.
    static var shortRows: [Row] { allRows.filter { [L("Открыть"), L("Переименовать"), L("На уровень выше"), L("В Корзину")].contains($0.action) } }

    var windowsKeys: Bool { didSet { if windowsKeys != oldValue { update(animated: true) } } }
    var onChange: ((Bool) -> Void)?

    private let grid = NSGridView()
    private let highlight = CALayer()
    private let hoverBox = CALayer()
    /// The column under the mouse (1 Finder, 2 Windows) when it isn't the chosen one.
    private var hoveredColumn: Int? { didSet { if hoveredColumn != oldValue { updateHover() } } }
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
        hoverBox.cornerRadius = 10
        hoverBox.borderWidth = 1
        hoverBox.opacity = 0
        layer?.addSublayer(hoverBox)
        layer?.addSublayer(highlight)

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBox.frame = hoveredColumn.map(columnRect) ?? hoverBox.frame
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(animated: false)
    }

    /// A column's box: from the headers down to the last row (both columns the same height).
    private func columnRect(_ column: Int) -> NSRect {
        func extent(_ column: Int) -> NSRect {
            (0..<grid.numberOfRows).reduce(NSRect.null) { rect, row in
                guard let view = grid.cell(atColumnIndex: column, rowIndex: row).contentView else { return rect }
                return rect.union(view.convert(view.bounds, to: self))
            }
        }
        let rect = extent(column), rows = extent(1).union(extent(2))
        let width = grid.column(at: column).width
        guard !rect.isNull else { return .zero }
        return NSRect(x: rect.midX - width / 2 - 6, y: rows.minY - 8, width: width + 12, height: rows.height + 16)
    }

    private func column(at point: NSPoint) -> Int? {
        [1, 2].first { columnRect($0).contains(point) }
    }

    private func placeHighlight() {
        grid.layoutSubtreeIfNeeded()
        highlight.frame = columnRect(windowsKeys ? 2 : 1)
    }

    // MARK: Mouse: the whole column is the button

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        return column(at: convert(point, from: superview)) != nil ? self : super.hitTest(point)
    }

    override func mouseMoved(with event: NSEvent) { trackHover(event) }
    override func mouseEntered(with event: NSEvent) { trackHover(event) }
    override func mouseExited(with event: NSEvent) { hoveredColumn = nil }

    private func trackHover(_ event: NSEvent) {
        let column = column(at: convert(event.locationInWindow, from: nil))
        hoveredColumn = column == (windowsKeys ? 2 : 1) ? nil : column
    }

    override func mouseDown(with event: NSEvent) {
        guard let column = column(at: convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        hoveredColumn = nil
        choose(column == 2)
    }

    override func resetCursorRects() {
        addCursorRect(columnRect(windowsKeys ? 1 : 2), cursor: .pointingHand)
    }

    /// The faint box and the brighter header and keys of the column the mouse is over.
    private func updateHover() {
        // The box jumps to its column (only fading is animated)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let hoveredColumn { hoverBox.frame = columnRect(hoveredColumn) }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        hoverBox.opacity = hoveredColumn == nil ? 0 : 1
        CATransaction.commit()
        finderHeader.isHovered = hoveredColumn == 1
        windowsHeader.isHovered = hoveredColumn == 2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            for cap in windowsCaps { cap.isHovered = hoveredColumn == 2 }
        }
    }

    private func update(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            highlight.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            hoverBox.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            hoverBox.borderColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        }
        placeHighlight()
        CATransaction.commit()
        finderHeader.isChosen = !windowsKeys
        windowsHeader.isChosen = windowsKeys
        window?.invalidateCursorRects(for: self)
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
    /// Its column is under the mouse: a switched-off key shows a little brighter.
    var isHovered = false { didSet { if isHovered != oldValue { animator().alphaValue = alpha } } }
    private var alpha: CGFloat { state == .on ? 1 : isHovered ? 0.7 : 0.45 }
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
        animator().alphaValue = alpha
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

/// "Как в Finder" / "Как в Windows" over a column.
private final class ColumnHeader: NSView {
    var isChosen = false { didSet { refresh() } }
    var isHovered = false { didSet { refresh() } }
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

    private func refresh() {
        let color: NSColor = isChosen ? .controlAccentColor : isHovered ? .labelColor : .secondaryLabelColor
        title.textColor = color
        icon.contentTintColor = color
    }
}
