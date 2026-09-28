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
    private var clearButton: NSButton?
    private var customization: FolderCustomization?
    private var tags: [FileTags.Tag]

    /// SF Symbols in Finder's sections (missing names are skipped).
    private static let symbolSections: [(String, [String])] = [
        (L("Люди"), ["person.fill", "person.2.fill", "person.crop.circle", "figure.stand", "figure.stand.dress", "figure.and.child.holdinghands",
                  "figure.arms.open", "figure.2", "figure.2.and.child.holdinghands", "figure.walk", "figure.wave", "figure.2.arms.open",
                  "figure", "face.smiling", "brain", "brain.head.profile", "eye", "eye.slash", "eyes", "eyebrow", "nose", "mustache",
                  "mouth", "ear", "ear.fill", "lungs.fill", "hand.raised.fill", "hand.raised.fingers.spread.fill", "hand.wave.fill",
                  "hand.thumbsup.fill", "hand.thumbsdown.fill", "hand.point.up.left.fill", "hand.tap.fill", "hand.point.right.fill",
                  "hand.point.left.fill", "hand.point.up.fill", "hands.clap.fill", "heart.fill", "star.fill"]),
        (L("Животные и природа"), ["hare.fill", "tortoise.fill", "dog.fill", "cat.fill", "lizard.fill", "bird.fill", "ant.fill",
                                "ladybug.fill", "fish.fill", "pawprint.fill", "leaf.fill", "tree.fill", "camera.macro", "carrot.fill",
                                "flame.fill", "drop.fill", "sun.max.fill", "moon.fill", "sparkles", "cloud.fill", "cloud.rain.fill",
                                "snowflake", "bolt.fill", "tornado", "mountain.2.fill", "globe.europe.africa.fill"]),
        (L("Работа и учёба"), ["briefcase.fill", "case.fill", "doc.text.fill", "doc.on.doc.fill", "folder.fill", "book.fill",
                            "books.vertical.fill", "book.closed.fill", "graduationcap.fill", "backpack.fill", "pencil", "highlighter",
                            "paintbrush.fill", "paintpalette.fill", "scissors", "ruler.fill", "hammer.fill", "wrench.and.screwdriver.fill",
                            "chart.bar.fill", "chart.pie.fill", "calendar", "clock.fill", "tray.full.fill", "archivebox.fill",
                            "paperclip", "lock.fill", "key.fill", "lightbulb.fill", "list.bullet.clipboard.fill", "signature"]),
        (L("Медиа"), ["photo.fill", "photo.on.rectangle", "camera.fill", "video.fill", "film.fill", "music.note", "music.note.list",
                   "headphones", "hifispeaker.fill", "mic.fill", "radio.fill", "guitars.fill", "pianokeys", "gamecontroller.fill",
                   "tv.fill", "play.rectangle.fill", "theatermasks.fill", "ticket.fill", "popcorn.fill", "paintbrush.pointed.fill"]),
        (L("Техника"), ["desktopcomputer", "laptopcomputer", "display", "iphone", "ipad", "applewatch", "keyboard", "computermouse.fill",
                     "printer.fill", "server.rack", "externaldrive.fill", "internaldrive.fill", "cpu.fill", "memorychip.fill",
                     "terminal.fill", "chevron.left.forwardslash.chevron.right", "network", "wifi", "antenna.radiowaves.left.and.right",
                     "globe", "cloud.fill", "icloud.fill", "gearshape.fill", "cube.fill", "shippingbox.fill", "battery.100"]),
        (L("Места и транспорт"), ["house.fill", "building.2.fill", "building.columns.fill", "storefront.fill", "tent.fill", "map.fill",
                               "mappin.and.ellipse", "location.fill", "airplane", "car.fill", "bus.fill", "tram.fill", "bicycle",
                               "scooter", "sailboat.fill", "ferry.fill", "suitcase.fill", "beach.umbrella.fill", "flag.fill", "signpost.right.fill"]),
        (L("Покупки и деньги"), ["cart.fill", "bag.fill", "basket.fill", "creditcard.fill", "banknote.fill", "dollarsign.circle.fill",
                              "eurosign.circle.fill", "giftcard.fill", "gift.fill", "tag.fill", "percent", "chart.line.uptrend.xyaxis",
                              "wallet.pass.fill", "receipt.fill"]),
        (L("Еда и здоровье"), ["fork.knife", "cup.and.saucer.fill", "mug.fill", "wineglass.fill", "birthday.cake.fill", "takeoutbag.and.cup.and.straw.fill",
                            "heart.text.square.fill", "cross.case.fill", "pills.fill", "stethoscope", "figure.run", "dumbbell.fill",
                            "sportscourt.fill", "soccerball", "basketball.fill", "tennis.racket"]),
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
        // Sizes and gaps as Finder's popover in macOS 26
        preview.widthAnchor.constraint(equalToConstant: 88).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let name = NSTextField(labelWithString: folder.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle

        tagRow.spacing = 8
        tagRow.alignment = .centerY

        let grid = symbolGrid()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 320).isActive = true
        // Auto Layout document view: pinned to the top of the clip view, as tall as its content
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        grid.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = grid
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: clip.topAnchor),
            grid.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
        ])

        let clear = NSButton(title: L("Очистить"), target: self, action: #selector(clearCustomization(_:)))
        let emoji = NSButton(title: L("Эмодзи"), image: NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)!,
                             target: self, action: #selector(pickEmoji(_:)))
        emoji.imagePosition = .imageLeading
        let buttons = NSStackView(views: [clear, emoji])
        buttons.distribution = .fillEqually
        buttons.spacing = 11
        clearButton = clear

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
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 7, right: 0)
        stack.setCustomSpacing(8, after: preview)
        stack.setCustomSpacing(11, after: name)
        stack.setCustomSpacing(30, after: tagRow)
        stack.setCustomSpacing(10, after: scroll)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        name.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -13).isActive = true
        view = stack
        refresh()
    }

    // MARK: - Symbols

    private func symbolGrid() -> NSView {
        // Six columns 44 pt apart after two narrow empty ones: the headers start after the first, the symbols after both
        let columns = 6
        var rows: [[NSView]] = []
        for (title, symbols) in Self.symbolSections {
            let header = NSTextField(labelWithString: title)
            header.font = .systemFont(ofSize: 13, weight: .semibold)
            rows.append([NSGridCell.emptyContentView, header] + Array(repeating: NSGridCell.emptyContentView, count: columns))
            var row: [NSView] = [NSGridCell.emptyContentView, NSGridCell.emptyContentView]
            for name in symbols {
                guard let image = NSImage(systemSymbolName: name, accessibilityDescription: name) else { continue }
                let button = NSButton(image: image.withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) ?? image,
                                      target: self, action: #selector(pickSymbol(_:)))
                button.isBordered = false
                button.identifier = NSUserInterfaceItemIdentifier(name)
                button.toolTip = name
                button.contentTintColor = .secondaryLabelColor
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                button.heightAnchor.constraint(equalToConstant: 40).isActive = true
                row.append(button)
                if row.count == columns + 2 { rows.append(row); row = [NSGridCell.emptyContentView, NSGridCell.emptyContentView] }
            }
            if row.count > 2 { rows.append(row + Array(repeating: NSGridCell.emptyContentView, count: columns + 2 - row.count)) }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 0
        grid.column(at: 0).width = 10
        grid.column(at: 1).width = 9.5
        for i in 0..<grid.numberOfRows where rows[i][1] is NSTextField {
            grid.row(at: i).mergeCells(in: NSRange(location: 1, length: columns + 1))
            grid.row(at: i).topPadding = i == 0 ? 11 : 6
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
        let color = tags.reversed().lazy.compactMap { FileTags.color(forIndex: $0.color) }.first
        preview.image = FolderIcon.render(tagColor: color, customization: customization)
        clearButton?.isEnabled = customization != nil
        // Highlight the chosen symbol
        for case let button as NSButton in (view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView?.subviews ?? []) {
            button.contentTintColor = customization == .symbol(button.identifier?.rawValue ?? "") ? .controlAccentColor : .secondaryLabelColor
        }

        tagRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // As in Finder: «remove all» (just the symbol), the favourite colours in their order (✓ on
        // the folder's), its other tags after them, «+» on a grey circle
        let removeAll = NSButton(image: NSImage(systemSymbolName: "tag.slash", accessibilityDescription: L("Снять теги"))?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) ?? NSImage(), target: self, action: #selector(removeAllTags(_:)))
        removeAll.isBordered = false
        removeAll.contentTintColor = tags.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        removeAll.toolTip = L("Снять все теги")
        removeAll.widthAnchor.constraint(equalToConstant: 22).isActive = true
        tagRow.addArrangedSubview(removeAll)
        let favorites = FileTags.favorites.filter { $0.color > 0 }
        let shown = favorites + tags.filter { tag in !favorites.contains { $0.name == tag.name } }
        for tag in shown {
            let applied = tags.contains { $0.name == tag.name }
            let button = circleButton(image: nil, color: tag.color, checked: applied, size: 26, action: #selector(toggleTag(_:)))
            button.toolTip = tag.name
            button.identifier = NSUserInterfaceItemIdentifier(tag.name)
            tagRow.addArrangedSubview(button)
        }
        let add = circleButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: L("Добавить тег"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)), color: nil, checked: false, size: 28, action: #selector(addCustomTag(_:)))
        add.toolTip = L("Добавить тег…")
        tagRow.addArrangedSubview(add)
    }

    private func circleButton(image: NSImage?, color: Int?, checked: Bool, size: CGFloat, action: Selector) -> NSButton {
        let picture = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let color, let fill = FileTags.color(forIndex: color) {
                fill.setFill()
                circle.fill()
                circle.lineWidth = 1
                (fill.shadow(withLevel: 0.25) ?? fill).setStroke()   // a thin darker rim, as Finder's
                circle.stroke()
            } else {
                NSColor.labelColor.withAlphaComponent(0.22).setFill()   // «+»: a grey circle
                circle.fill()
            }
            if checked, let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .bold)) {
                let tinted = NSImage(size: check.size, flipped: false) { r in
                    check.draw(in: r); NSColor.white.setFill(); r.fill(using: .sourceIn); return true
                }
                tinted.draw(in: DesktopView.aspectFit(tinted.size, in: rect.insetBy(dx: 6, dy: 6)))
            }
            if let image {
                let white = NSImage(size: image.size, flipped: false) { r in
                    image.draw(in: r); NSColor.white.setFill(); r.fill(using: .sourceIn); return true
                }
                white.draw(in: DesktopView.aspectFit(image.size, in: rect.insetBy(dx: 9, dy: 9)))
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
        alert.messageText = L("Новый тег")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = L("Название тега")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Добавить"))
        alert.addButton(withTitle: L("Отменить"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tags.contains(where: { $0.name == name }) else { return }
        tags.append(FileTags.tag(named: name, knownTags: tags))
        saveTags()
    }

    private func saveTags() {
        let before = [folder: FileTags.tags(of: folder)]
        do { try FileTags.setTags(tags, on: folder) } catch { NSAlert(error: error).runModal() }
        FileUndo.recordTags(before: before)
        refresh()
        NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
    }
}

/// Clip view with a top-left origin, so a document view shorter than the clip sticks to the top.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
