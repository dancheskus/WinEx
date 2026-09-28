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
        (L("Люди"), ["person.fill", "person.2.fill", "person.crop.circle", "figure.stand", "figure.stand.dress", "figure.child",
                  "figure", "figure.2", "figure.2.and.child.holdinghands", "figure.and.child.holdinghands", "figure.arms.open", "figure.2.arms.open",
                  "accessibility", "face.smiling.inverse", "brain", "brain.head.profile.fill", "eye", "eye.circle.fill",
                  "eyes", "eyebrow", "nose.fill", "mustache.fill", "mouth.fill", "ear",
                  "ear.fill", "lungs.fill", "hand.raised.fill", "hand.raised.fingers.spread.fill", "hand.wave.fill", "hand.thumbsup.fill",
                  "hand.thumbsdown.fill", "hand.point.up.left.fill", "hand.tap.fill", "hand.draw.fill", "rectangle.and.hand.point.up.left.fill",
                  "hand.point.right.fill", "hand.point.left.fill", "hand.point.up.fill", "hand.point.up.braille.fill", "hand.point.down.fill",
                  "hands.clap.fill", "heart.fill", "star.fill"]),
        (L("Животные и природа"), ["hare.fill", "tortoise.fill", "dog.fill", "cat.fill", "lizard.fill", "bird.fill",
                                "ant.fill", "ladybug.fill", "fish.fill", "pawprint.fill", "leaf.fill", "globe.americas.fill",
                                "globe.europe.africa.fill", "globe.asia.australia.fill", "globe.central.south.asia.fill", "sun.max.fill", "sunrise.fill", "sunset.fill",
                                "sun.horizon.fill", "moon.fill", "sparkle", "moon.stars.fill", "cloud.fill", "cloud.rain.fill",
                                "cloud.heavyrain.fill", "cloud.snow.fill", "cloud.bolt.fill", "cloud.sun.fill", "cloud.moon.fill", "wind",
                                "snowflake", "tornado", "tropicalstorm", "hurricane", "thermometer.medium", "rainbow",
                                "drop.fill", "water.waves", "flame.fill", "mountain.2.fill", "tree.fill", "camera.macro",
                                "sun.dust.fill", "fossil.shell.fill", "atom"]),
        (L("Еда и напитки"), ["fork.knife", "cup.and.saucer.fill", "cup.and.heat.waves.fill", "mug.fill", "takeoutbag.and.cup.and.straw.fill",
                           "wineglass.fill", "waterbottle.fill", "carrot.fill", "frying.pan.fill", "popcorn.fill", "birthday.cake.fill"]),
        (L("Активность"), ["soccerball", "baseball.fill", "basketball.fill", "american.football.fill", "australian.football.fill", "rugbyball.fill",
                        "tennis.racket", "hockey.puck.fill", "cricket.ball.fill", "tennisball.fill", "volleyball.fill", "sportscourt.fill",
                        "skateboard.fill", "skis.fill", "snowboard.fill", "surfboard.fill", "oar.2.crossed", "drone.fill",
                        "dumbbell.fill", "guitars.fill", "gamecontroller.fill", "arcade.stick.console.fill", "figure.walk", "figure.wave",
                        "figure.fall", "figure.run", "figure.run.treadmill", "figure.walk.treadmill", "figure.roll", "figure.roll.runningpace",
                        "figure.american.football", "figure.archery", "figure.australian.football", "figure.badminton", "figure.barre",
                        "figure.baseball", "figure.basketball", "figure.bowling", "figure.boxing", "figure.climbing", "figure.cooldown",
                        "figure.core.training", "figure.cricket", "figure.skiing.crosscountry", "figure.cross.training", "figure.curling",
                        "figure.dance", "figure.disc.sports", "figure.skiing.downhill", "figure.elliptical", "figure.equestrian.sports",
                        "figure.fencing", "figure.fishing", "figure.flexibility", "figure.strengthtraining.functional", "figure.golf",
                        "figure.gymnastics", "figure.hand.cycling", "figure.handball", "figure.highintensity.intervaltraining", "figure.hiking",
                        "figure.hockey", "figure.field.hockey", "figure.ice.hockey", "figure.indoor.cycle", "figure.jumprope", "figure.kickboxing",
                        "figure.lacrosse", "figure.martial.arts", "figure.mind.and.body", "figure.mixed.cardio", "figure.open.water.swim",
                        "figure.outdoor.cycle", "figure.pickleball", "figure.pilates", "figure.play", "figure.pool.swim", "figure.racquetball",
                        "figure.rolling", "figure.rower", "figure.rugby", "figure.sailing", "figure.skateboarding", "figure.ice.skating",
                        "figure.snowboarding", "figure.soccer", "figure.socialdance", "figure.softball", "figure.squash", "figure.stair.stepper",
                        "figure.stairs", "figure.step.training", "figure.surfing", "figure.table.tennis", "figure.taichi", "figure.tennis",
                        "figure.track.and.field", "figure.strengthtraining.traditional", "figure.volleyball", "figure.water.fitness",
                        "figure.waterpolo", "figure.wrestling", "figure.yoga"]),
        (L("Путешествия и места"), ["airplane", "airplane.departure", "figure.walk.suitcase.rolling", "car.fill", "car.2.fill", "bolt.car.fill",
                                 "car.side.fill", "suv.side.fill", "truck.pickup.side.fill", "convertible.side.fill", "steeringwheel", "tire",
                                 "road.lanes", "arrow.triangle.turn.up.right.diamond.fill", "fuelpump.fill", "ev.charger.fill", "box.truck.fill", "bus.fill",
                                 "tram.fill", "lightrail.fill", "tram.fill.tunnel", "ferry.fill", "sailboat.fill", "helmet.fill",
                                 "scooter", "bicycle", "moped.fill", "motorcycle.fill", "stroller.fill", "wheelchair",
                                 "paperplane.fill", "map.fill", "mappin.and.ellipse", "house.fill", "house.and.flag.fill", "storefront.fill",
                                 "building.fill", "building.2.fill", "building.columns.fill", "tent.fill", "beach.umbrella.fill", "suitcase.fill"]),
        (L("Предметы"), [
            "pencil", "pencil.tip.crop.circle", "pencil.line", "eraser.fill", "scissors", "pencil.and.ruler.fill",
            "ruler.fill", "level.fill", "paperclip", "link", "trash.fill", "bookmark.fill",
            "pin.fill", "lock.fill", "key.fill", "key.2.on.ring.fill", "speaker.wave.3.fill", "magnifyingglass",
            "mic.fill", "music.mic", "paperplane.fill", "tray.fill", "archivebox.fill", "doc",
            "list.clipboard.fill", "receipt.fill", "note.text", "calendar", "book.fill", "books.vertical.fill",
            "book.closed.fill", "text.book.closed.fill", "menucard.fill", "newspaper.fill", "graduationcap.fill", "studentdesk",
            "compass.drawing", "globe.desk.fill", "person.text.rectangle", "person.text.rectangle.fill", "photo.fill", "rosette",
            "trophy.fill", "medal.fill", "fire.extinguisher.fill", "umbrella.fill", "beach.umbrella.fill", "megaphone.fill",
            "shield.lefthalf.filled", "checkerboard.shield", "flag.fill", "flag.checkered", "flag.2.crossed.fill", "flag.checkered.2.crossed",
            "bell.fill", "tag.fill", "plus.slash.minus", "flashlight.off.fill", "qrcode", "barcode",
            "camera.fill", "camera.viewfinder", "doc.viewfinder.fill", "phone.fill", "video.fill", "envelope.fill",
            "envelope.open.fill", "mail.fill", "gear", "gearshape.2.fill", "bag.fill", "cart.fill",
            "basket.fill", "creditcard.fill", "giftcard.fill", "wallet.bifold.fill", "gift.fill", "shippingbox.fill",
            "timer", "metronome.fill", "wrench.and.screwdriver.fill", "pianokeys", "tuningfork", "paintbrush.fill",
            "paintbrush.pointed.fill", "paintpalette.fill", "swatchpalette.fill", "theatermasks.fill", "theatermask.and.paintbrush.fill", "wrench.adjustable.fill",
            "hammer.fill", "screwdriver.fill", "eyedropper.halffull", "wand.and.stars", "scroll.fill", "puzzlepiece.fill",
            "puzzlepiece.extension.fill", "dice.fill", "teddybear.fill", "printer.fill", "scanner.fill", "backpack.fill",
            "duffle.bag.fill", "handbag.fill", "briefcase.fill", "case.fill", "cross.case.fill", "suitcase.fill",
            "suitcase.rolling.fill", "lightbulb.fill", "fanblades.fill", "fan.desk.fill", "lamp.desk.fill", "chandelier.fill",
            "light.beacon.max.fill", "powerplug.fill", "web.camera.fill", "door.left.hand.closed", "door.garage.closed", "window.vertical.closed",
            "sprinkler.fill", "spigot.fill", "shower.fill", "hifireceiver.fill", "av.remote.fill", "videoprojector.fill",
            "party.popper.fill", "balloon.2.fill", "rays", "fireworks", "bed.double.fill", "sofa.fill",
            "chair.lounge.fill", "chair.fill", "cabinet.fill", "stove.fill", "microwave.fill", "refrigerator.fill",
            "sink.fill", "toilet.fill", "cpu.fill", "memorychip.fill", "sdcard.fill", "opticaldisc.fill",
            "display", "desktopcomputer", "desktopcomputer.and.macbook", "laptopcomputer", "xserve", "iphone",
            "ipad", "vision.pro.fill", "applewatch", "watch.analog", "homepod.fill", "keyboard.fill",
            "headphones", "headset", "hifispeaker.fill", "tv", "radio.fill", "antenna.radiowaves.left.and.right",
            "dot.radiowaves.up.forward", "battery.100", "minus.plus.batteryblock.fill", "horn.blast.fill", "stethoscope", "medical.thermometer.fill",
            "syringe.fill", "bandage.fill", "facemask.fill", "pill.fill", "flask.fill", "testtube.2",
            "cross.vial.fill", "hanger", "crown.fill", "hat.widebrim.fill", "hat.cap.fill", "comb.fill",
            "eyeglasses", "sunglasses.fill", "binoculars.fill", "tshirt.fill", "jacket.fill", "coat.fill",
            "shoe.fill", "shoeprints.fill", "film.fill", "movieclapper.fill", "ticket.fill", "hourglass",
            "clock.fill", "alarm.fill", "stopwatch.fill", "gauge.with.dots.needle.33percent", "gauge.with.dots.needle.50percent", "gauge.with.dots.needle.67percent",
        ]),
        (L("Символы"), [
            "heart.fill", "star.fill", "star.leadinghalf.filled", "peacesign", "nosign", "network",
            "info.circle.fill", "arrow.3.trianglepath", "exclamationmark.triangle.fill", "bolt.fill", "sparkle", "cross.fill",
            "asterisk", "arrowshape.left.fill", "arrowshape.right.fill", "arrowshape.up.fill", "arrowshape.down.fill", "arrowshape.turn.up.left.fill",
            "arrowshape.turn.up.right.fill", "arrow.merge", "arrow.branch", "play.fill", "circle.circle.fill", "music.note",
            "music.note.list", "music.quarternote.3", "shuffle", "infinity", "location.fill", "checkmark.seal.fill",
            "checklist", "checkmark", "checkmark.circle.fill", "xmark", "xmark.circle.fill", "questionmark",
            "questionmark.circle.fill", "exclamationmark", "exclamationmark.2", "exclamationmark.3", "exclamationmark.circle.fill", "bubble.left.fill",
            "exclamationmark.bubble.fill", "bubble.left.and.bubble.right.fill", "quote.opening", "circle.grid.3x3.fill", "circle.hexagongrid.fill", "square.grid.3x3.fill",
            "square.grid.2x2.fill", "rectangle.grid.3x2.fill", "circle.grid.cross", "point.topleft.down.to.point.bottomright.curvepath", "point.bottomleft.forward.to.point.topright.scurvepath", "point.3.connected.trianglepath.dotted",
            "square.stack.3d.down.right.fill", "slider.horizontal.3", "slider.vertical.3", "cube.fill", "chart.xyaxis.line", "chart.pie.fill",
            "chart.bar.fill", "chart.bar.xaxis.ascending", "chart.line.uptrend.xyaxis", "square.3.layers.3d", "tablecells", "point.topleft.down.curvedto.point.bottomright.up",
            "angle", "perspective", "waveform.path", "waveform", "recordingtape", "list.bullet",
            "x.squareroot", "percent", "function", "plus.forwardslash.minus", "plus", "minus",
            "lessthan", "greaterthan", "number",
        ]),
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
