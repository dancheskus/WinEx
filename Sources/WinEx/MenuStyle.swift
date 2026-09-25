import AppKit

/// Context menus in the style of Windows 11 Explorer: a row of the everyday actions as icon buttons
/// on top, then items with icons and their shortcuts on the right.
@MainActor
enum MenuStyle {
    /// Icon and shortcut per action (shortcuts only show; the main menu is what handles the keys).
    private static let looks: [String: (symbol: String, key: String, modifiers: NSEvent.ModifierFlags)] = [
        "openSelected:": ("arrow.up.forward.square", String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), .command),
        "quickLook:": ("eye", " ", []),
        "openInNewTab:": ("plus.rectangle.on.rectangle", "", []),
        "openInNewWindow:": ("macwindow.badge.plus", "", []),
        "showPackageContents:": ("shippingbox", "", []),
        "showOriginal:": ("arrowshape.turn.up.backward", "", []),
        "revealInFolder:": ("folder", "", []),
        "cut:": ("scissors", "x", .command),
        "copy:": ("doc.on.doc", "c", .command),
        "paste:": ("doc.on.clipboard", "v", .command),
        "copyPath:": ("link", "c", [.command, .option]),
        "duplicate:": ("plus.square.on.square", "d", .command),
        "makeAlias:": ("arrowshape.turn.up.right", "a", [.command, .control]),
        "compress:": ("archivebox", "", []),
        "extractArchive:": ("shippingbox.and.arrow.backward", "", []),
        "renameSelected:": ("pencil", "", []),
        "moveToTrash:": ("trash", String(Character(UnicodeScalar(NSBackspaceCharacter)!)), .command),
        "share:": ("square.and.arrow.up", "", []),
        "customizeFolder:": ("paintbrush", "", []),
        "showProperties:": ("info.circle", "i", .command),
        "putBackFromTrash:": ("arrow.uturn.backward", "", []),
        "deleteForever:": ("trash.slash", "", []),
        "emptyTrash:": ("trash", "", []),
        "openFullDiskAccess:": ("lock.shield", "", []),
        "refresh:": ("arrow.clockwise", "r", .command),
        "refreshAction:": ("arrow.clockwise", "r", .command),
        "openDesktopAction:": ("folder", "", []),
        "openWallpaperSettings:": ("photo", "", []),
        "showSettings:": ("gearshape", ",", .command),
        "newFolder:": ("folder.badge.plus", "N", .command),
    ]

    /// Submenus by title.
    private static let submenuSymbols: [String: String] = [
        "Вид": "square.grid.2x2", "Сортировка": "arrow.up.arrow.down", "Создать": "plus.circle",
        "Открыть с помощью": "arrow.up.forward.app", "Теги": "tag",
    ]

    /// Gives every item of `menu` its icon and shortcut. The icon goes into the title (a text
    /// attachment): macOS 27 doesn't draw `NSMenuItem.image` in context menus.
    static func decorate(_ menu: NSMenu) {
        let items = menu.items.filter { !$0.isSeparatorItem && $0.view == nil }
        // Submenus too ("Открыть с помощью" with app icons, "Создать", "Вид")
        items.compactMap(\.submenu).forEach(decorate)
        var icons: [NSMenuItem: NSImage] = [:]
        // Already decorated (the file menu is decorated when built and again when opened)
        for item in items where item.attributedTitle?.containsAttachments != true {
            let look = item.action.flatMap { looks[NSStringFromSelector($0)] }
            if let look, item.keyEquivalent.isEmpty && !look.key.isEmpty {
                item.keyEquivalent = look.key
                item.keyEquivalentModifierMask = look.modifiers
            }
            // An image set by the menu's builder wins (e.g. the app that "Открыть" uses)
            if let image = item.image {
                icons[item] = image
            } else if let look {
                icons[item] = symbol(look.symbol)
            } else if item.submenu != nil, let name = submenuSymbols.first(where: { item.title.hasPrefix($0.key) })?.value {
                icons[item] = symbol(name)
            }
        }
        guard !icons.isEmpty else { return }
        // Roomier than the stock menu, like Explorer's: bigger text, a tall frame per icon.
        // The shortcut is drawn in the title too (right-aligned at a tab stop): then text and
        // shortcut share one line, centred in the row — AppKit places its own shortcut by other rules.
        let font = NSFont.menuFont(ofSize: 14)
        let todo = items.filter { $0.attributedTitle == nil || $0.attributedTitle?.containsAttachments == false }
        let widest = todo.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        // At the menu's right edge: the button row (if any) makes the menu wider than the texts
        let rowWidth = menu.items.compactMap { $0.view as? ActionRowView }.first?.frame.width ?? 0
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: ceil(max(22 + 12 + widest + 70, rowWidth - 36)))]
        // Roomy rows come from the menu's own (larger) font: AppKit sizes the rows for it and
        // centres its submenu arrows and shortcuts in them. The 14 pt text is raised by half the
        // difference of the two line heights, so it sits in the middle too. (A tall icon or a big
        // line height made the rows roomy as well, but left the arrow off-centre.)
        let rowFont = NSFont.menuFont(ofSize: 18)
        menu.font = rowFont
        let raise = (((rowFont.ascender - rowFont.descender) - (font.ascender - font.descender)) / 2).rounded()
        let middle = (font.ascender + font.descender) / 2
        for item in todo {
            let attachment = NSTextAttachment()
            attachment.image = framed(icons[item])
            attachment.bounds = NSRect(x: 0, y: (middle - 10).rounded(), width: 22, height: 20)
            let title = NSMutableAttributedString(attachment: attachment)
            title.append(NSAttributedString(string: "   " + item.title, attributes: [.font: font, .paragraphStyle: paragraph]))
            if let shortcut = shortcutText(item) {
                title.append(NSAttributedString(string: "\t" + shortcut, attributes: [
                    .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                // Shown, not handled here: the main menu owns the keys
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
            title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
            title.addAttribute(.baselineOffset, value: raise, range: NSRange(location: 0, length: title.length))
            item.attributedTitle = title
            item.image = nil
        }
    }

    /// "⌥⌘C" for an item's key equivalent (nil when it has none).
    private static func shortcutText(_ item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var modifiers = item.keyEquivalentModifierMask
        var name: String
        switch key {
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): name = "↓"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): name = "↑"
        case String(Character(UnicodeScalar(NSBackspaceCharacter)!)): name = "⌫"
        case "\r": name = "↩"
        case " ": name = "Пробел"
        default:
            // Upper-case letters stand for ⇧ + letter in key equivalents
            if key.uppercased() == key && key.lowercased() != key { modifiers.insert(.shift) }
            name = key.uppercased()
        }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + name
    }

    /// Every icon in the same 22×20 frame, centred and scaled
    /// down to fit, so the texts line up. Symbols are drawn as a one-colour mask in the menu's
    /// text colour: any layered rendering (hierarchical, palette) left the fill layers of some
    /// symbols ("tag", "plus.square.on.square") black. App icons keep their colours.
    private static func framed(_ icon: NSImage?) -> NSImage {
        let color = menuTextColor
        return NSImage(size: NSSize(width: 22, height: 20), flipped: false) { rect in
            guard let icon, icon.size.width > 0, icon.size.height > 0 else { return true }
            let scale = min(1, 20 / icon.size.width, 20 / icon.size.height)
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let target = NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height)
            guard icon.isTemplate else {
                icon.draw(in: target)
                return true
            }
            // Mask → colour: draw the symbol, then paint over only where it is
            let tinted = NSImage(size: size, flipped: false) { area in
                icon.draw(in: area)
                color.set()
                area.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: target)
            return true
        }
    }

    /// The menu's text colour for the current appearance (resolved: a dynamic colour inside an
    /// image may be resolved for the wrong appearance).
    private static var menuTextColor: NSColor {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.12, alpha: 1)
    }

    /// A plain (template) symbol; `framed` gives it the menu's colour.
    static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// The row of icon buttons on top of a file menu.
    static func actionRow(target: AnyObject, actions: [(title: String, symbol: String, action: Selector)]) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = ActionRowView(target: target, actions: actions)
        return item
    }
}

/// Explorer's row of big icon buttons with captions (cut, copy, rename, share, delete).
private final class ActionRowView: NSView {
    private let actions: [(title: String, symbol: String, action: Selector)]
    private weak var target: AnyObject?
    private var hovered: Int? { didSet { needsDisplay = true } }
    private static let buttonSize = NSSize(width: 80, height: 62), inset: CGFloat = 8

    init(target: AnyObject, actions: [(title: String, symbol: String, action: Selector)]) {
        self.target = target
        self.actions = actions
        let width = Self.inset * 2 + CGFloat(actions.count) * Self.buttonSize.width
        super.init(frame: NSRect(x: 0, y: 0, width: max(width, 300), height: Self.buttonSize.height + 12))
        // As wide as the menu: the buttons share the whole width (no gap on the right)
        autoresizingMask = [.width]
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rect(_ index: Int) -> NSRect {
        let width = (bounds.width - Self.inset * 2) / CGFloat(max(actions.count, 1))
        return NSRect(x: Self.inset + CGFloat(index) * width, y: (bounds.height - Self.buttonSize.height) / 2,
                      width: width, height: Self.buttonSize.height)
    }

    private func index(at point: NSPoint) -> Int? {
        actions.indices.first { rect($0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, entry) in actions.enumerated() {
            let area = rect(i)
            if hovered == i {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: area.insetBy(dx: 2, dy: 0), xRadius: 8, yRadius: 8).fill()
            }
            if let image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
                    .applying(.init(hierarchicalColor: .labelColor))) {
                let size = image.size
                image.draw(in: NSRect(x: area.midX - size.width / 2, y: area.maxY - 8 - size.height, width: size.width, height: size.height))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            (entry.title as NSString).draw(in: NSRect(x: area.minX + 2, y: area.minY + 5, width: area.width - 4, height: 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ])
        }
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        let action = actions[i].action
        let target = target
        enclosingMenuItem?.menu?.cancelTracking()
        // After the menu is gone (renaming needs the window's focus back)
        DispatchQueue.main.async { NSApp.sendAction(action, to: target, from: nil) }
    }
}
