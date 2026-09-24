import AppKit

/// "Настроить папку…" — like Finder's popover in macOS 26: live preview, tags (remove all, the
/// folder's tags, the other favorites, "+" for a custom one), a grid of symbols, "Очистить" and "Эмодзи".
/// Every change is written immediately, in Finder's own format.
final class FolderCustomizationController: NSViewController, NSTextFieldDelegate {
    /// Shows the popover next to `rect` in `view`.
    static func show(for folder: URL, relativeTo rect: NSRect, of view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = FolderCustomizationController(folder: folder)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    private let folder: URL
    private let preview = NSImageView()
    private let tagRow = NSStackView()
    private let emojiCatcher = NSTextField()
    private var customization: FolderCustomization?
    private var tags: [FileTags.Tag]

    /// Curated SF Symbols, in the same spirit as Finder's sections.
    private static let symbolSections: [(String, [String])] = [
        ("Люди", ["person.fill", "person.2.fill", "person.crop.circle", "figure.stand", "figure.2.and.child.holdinghands",
                  "face.smiling", "brain.head.profile", "eye", "hand.raised.fill", "hand.thumbsup.fill", "heart.fill", "star.fill"]),
        ("Животные и природа", ["hare.fill", "tortoise.fill", "dog.fill", "cat.fill", "bird.fill", "fish.fill",
                                "pawprint.fill", "leaf.fill", "tree.fill", "flame.fill", "drop.fill", "sun.max.fill",
                                "moon.fill", "cloud.fill", "snowflake", "bolt.fill"]),
        ("Работа и учёба", ["briefcase.fill", "doc.text.fill", "folder.fill", "book.fill", "graduationcap.fill", "pencil",
                            "paintbrush.fill", "hammer.fill", "wrench.and.screwdriver.fill", "chart.bar.fill", "calendar",
                            "tray.full.fill", "archivebox.fill", "paperclip", "lock.fill", "key.fill"]),
        ("Медиа", ["photo.fill", "camera.fill", "video.fill", "film.fill", "music.note", "headphones", "mic.fill",
                   "gamecontroller.fill", "tv.fill", "play.rectangle.fill"]),
        ("Техника", ["desktopcomputer", "laptopcomputer", "iphone", "keyboard", "server.rack", "externaldrive.fill",
                     "cpu.fill", "terminal.fill", "chevron.left.forwardslash.chevron.right", "network", "wifi", "globe"]),
        ("Места и транспорт", ["house.fill", "building.2.fill", "map.fill", "mappin.and.ellipse", "airplane", "car.fill",
                               "bicycle", "tram.fill", "ferry.fill", "suitcase.fill"]),
        ("Покупки и деньги", ["cart.fill", "bag.fill", "creditcard.fill", "banknote.fill", "gift.fill", "tag.fill"]),
    ]

    init(folder: URL) {
        self.folder = folder
        self.customization = FolderCustomization.read(folder)
        self.tags = FileTags.tags(of: folder)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.widthAnchor.constraint(equalToConstant: 96).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = NSTextField(labelWithString: folder.displayName)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle

        tagRow.spacing = 8
        tagRow.alignment = .centerY

        let grid = symbolGrid()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 330).isActive = true
        // Auto Layout document view: pinned to the top of the clip view, as tall as its content
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        grid.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = grid
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: clip.topAnchor),
            grid.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
        ])

        let clear = NSButton(title: "Очистить", target: self, action: #selector(clearCustomization(_:)))
        let emoji = NSButton(title: "Эмодзи", image: NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)!,
                             target: self, action: #selector(pickEmoji(_:)))
        emoji.imagePosition = .imageLeading
        let buttons = NSStackView(views: [clear, emoji])
        buttons.distribution = .fillEqually

        // Receives the character-palette input for "Эмодзи"
        emojiCatcher.delegate = self
        emojiCatcher.isBordered = false
        emojiCatcher.drawsBackground = false
        emojiCatcher.textColor = .clear
        emojiCatcher.widthAnchor.constraint(equalToConstant: 1).isActive = true
        emojiCatcher.heightAnchor.constraint(equalToConstant: 1).isActive = true
        emojiCatcher.alphaValue = 0  // invisible, but can still take the palette's input

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [preview, name, tagRow, separator, scroll, buttons, emojiCatcher])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 12, right: 14)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        view = stack
        refresh()
    }

    // MARK: - Symbols

    private func symbolGrid() -> NSView {
        let columns = 6
        var rows: [[NSView]] = []
        for (title, symbols) in Self.symbolSections {
            let header = NSTextField(labelWithString: title)
            header.font = .systemFont(ofSize: 13, weight: .semibold)
            rows.append([header] + Array(repeating: NSGridCell.emptyContentView, count: columns - 1))
            var row: [NSView] = []
            for name in symbols {
                guard let image = NSImage(systemSymbolName: name, accessibilityDescription: name) else { continue }
                let button = NSButton(image: image.withSymbolConfiguration(.init(pointSize: 20, weight: .regular)) ?? image,
                                      target: self, action: #selector(pickSymbol(_:)))
                button.isBordered = false
                button.identifier = NSUserInterfaceItemIdentifier(name)
                button.toolTip = name
                button.contentTintColor = .secondaryLabelColor
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                button.heightAnchor.constraint(equalToConstant: 36).isActive = true
                row.append(button)
                if row.count == columns { rows.append(row); row = [] }
            }
            if !row.isEmpty { rows.append(row + Array(repeating: NSGridCell.emptyContentView, count: columns - row.count)) }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 2
        grid.columnSpacing = 6
        for i in 0..<grid.numberOfRows where rows[i].first is NSTextField {
            grid.row(at: i).mergeCells(in: NSRange(location: 0, length: columns))
            grid.row(at: i).topPadding = 8
        }
        return grid
    }

    @objc private func pickSymbol(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        apply(customization == .symbol(name) ? nil : .symbol(name))
    }

    @objc private func pickEmoji(_ sender: Any?) {
        emojiCatcher.stringValue = ""
        view.window?.makeFirstResponder(emojiCatcher)
        NSApp.orderFrontCharacterPalette(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        // Keep the last character typed or picked in the palette
        guard let last = emojiCatcher.stringValue.last else { return }
        emojiCatcher.stringValue = ""
        apply(.emoji(String(last)))
    }

    @objc private func clearCustomization(_ sender: Any?) {
        apply(nil)
    }

    private func apply(_ value: FolderCustomization?) {
        do {
            try FolderCustomization.write(value, to: folder)
            customization = value
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
        NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
    }

    // MARK: - Tags

    private func refresh() {
        let color = tags.lazy.compactMap { FileTags.color(forIndex: $0.color) }.first
        preview.image = FolderIcon.render(tagColor: color, customization: customization)
        // Highlight the chosen symbol
        for case let button as NSButton in (view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView?.subviews ?? []) {
            button.contentTintColor = customization == .symbol(button.identifier?.rawValue ?? "") ? .controlAccentColor : .secondaryLabelColor
        }

        tagRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let removeAll = circleButton(image: NSImage(systemSymbolName: "tag.slash", accessibilityDescription: "Снять теги")!,
                                     color: nil, checked: false, action: #selector(removeAllTags(_:)))
        removeAll.toolTip = "Снять все теги"
        tagRow.addArrangedSubview(removeAll)
        let applied = tags
        for tag in applied {
            let button = circleButton(image: nil, color: tag.color, checked: true, action: #selector(toggleTag(_:)))
            button.toolTip = tag.name
            button.identifier = NSUserInterfaceItemIdentifier(tag.name)
            tagRow.addArrangedSubview(button)
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        tagRow.addArrangedSubview(divider)
        for tag in FileTags.favorites where !applied.contains(where: { $0.name == tag.name }) {
            let button = circleButton(image: nil, color: tag.color, checked: false, action: #selector(toggleTag(_:)))
            button.toolTip = tag.name
            button.identifier = NSUserInterfaceItemIdentifier(tag.name)
            tagRow.addArrangedSubview(button)
        }
        let add = circleButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Добавить тег")!,
                               color: nil, checked: false, action: #selector(addCustomTag(_:)))
        add.toolTip = "Добавить тег…"
        tagRow.addArrangedSubview(add)
    }

    private func circleButton(image: NSImage?, color: Int?, checked: Bool, action: Selector) -> NSButton {
        let size: CGFloat = 26
        let picture = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color, let fill = FileTags.color(forIndex: color) {
                fill.setFill()
                circle.fill()
            } else {
                NSColor.quaternaryLabelColor.setFill()
                circle.fill()
            }
            if checked, let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .bold)) {
                let tinted = NSImage(size: check.size, flipped: false) { r in
                    check.draw(in: r); NSColor.white.setFill(); r.fill(using: .sourceIn); return true
                }
                tinted.draw(in: DesktopView.aspectFit(tinted.size, in: rect.insetBy(dx: 7, dy: 7)))
            }
            if let image {
                image.draw(in: DesktopView.aspectFit(image.size, in: rect.insetBy(dx: 6, dy: 6)))
            }
            return true
        }
        let button = NSButton(image: picture, target: self, action: action)
        button.isBordered = false
        button.widthAnchor.constraint(equalToConstant: size).isActive = true
        button.heightAnchor.constraint(equalToConstant: size).isActive = true
        return button
    }

    @objc private func toggleTag(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        if tags.contains(where: { $0.name == name }) {
            tags.removeAll { $0.name == name }
        } else {
            tags.append(FileTags.tag(named: name, knownTags: tags))
        }
        saveTags()
    }

    @objc private func removeAllTags(_ sender: Any?) {
        tags = []
        saveTags()
    }

    @objc private func addCustomTag(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Новый тег"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Название тега"
        alert.accessoryView = field
        alert.addButton(withTitle: "Добавить")
        alert.addButton(withTitle: "Отменить")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tags.contains(where: { $0.name == name }) else { return }
        tags.append(FileTags.tag(named: name, knownTags: tags))
        saveTags()
    }

    private func saveTags() {
        do { try FileTags.setTags(tags, on: folder) } catch { NSAlert(error: error).runModal() }
        refresh()
        NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
    }
}

/// Clip view with a top-left origin, so a document view shorter than the clip sticks to the top.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
