import AppKit

/// A list as in System Settings: a rounded box with the table and, under it inside the box, a strip
/// of + / − buttons.
final class ListBox: NSView {
    private let bar = NSView()
    private let line = NSBox()

    /// `buttons` from `ListBox.button` (none: no strip). The scroll view's height is the list's.
    init(_ scroll: NSScrollView, buttons: [NSButton] = []) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        guard !buttons.isEmpty else {
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            return
        }
        line.boxType = .separator
        var views: [NSView] = []
        for button in buttons {
            let divider = NSBox()
            divider.boxType = .separator
            views += [button, divider]
            divider.heightAnchor.constraint(equalToConstant: 14).isActive = true
        }
        let row = NSStackView(views: views)
        row.spacing = 0
        for view in [line, row, bar] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(bar)
        bar.addSubview(line)
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 24),
            line.topAnchor.constraint(equalTo: bar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 2),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A borderless + / − (or any symbol) for the strip.
    static func button(_ symbol: String, _ description: String, target: AnyObject?, action: Selector, into button: NSButton = NSButton()) -> NSButton {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .labelColor
        button.toolTip = description
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
    }
}
