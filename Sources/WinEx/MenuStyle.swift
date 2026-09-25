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
        for item in items {
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
        // Items without an icon keep the same indent, so the texts line up
        for item in items where item.attributedTitle == nil || item.attributedTitle?.containsAttachments == false {
            let attachment = NSTextAttachment()
            attachment.image = framed(icons[item])
            attachment.bounds = NSRect(x: 0, y: -4, width: 20, height: 18)
            let title = NSMutableAttributedString(attachment: attachment)
            title.append(NSAttributedString(string: "  " + item.title, attributes: [.font: menu.font ?? NSFont.menuFont(ofSize: 0)]))
            item.attributedTitle = title
            item.image = nil
        }
    }

    /// Every icon in the same 20×18 frame, centred and scaled down to fit, so the texts line up.
    private static func framed(_ icon: NSImage?) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            guard let icon, icon.size.width > 0, icon.size.height > 0 else { return true }
            let scale = min(1, 16 / icon.size.width, 16 / icon.size.height)
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            icon.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            return true
        }
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(.init(hierarchicalColor: .labelColor)))
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
    private static let buttonSize = NSSize(width: 78, height: 56), inset: CGFloat = 10

    init(target: AnyObject, actions: [(title: String, symbol: String, action: Selector)]) {
        self.target = target
        self.actions = actions
        let width = Self.inset * 2 + CGFloat(actions.count) * Self.buttonSize.width
        super.init(frame: NSRect(x: 0, y: 0, width: max(width, 300), height: Self.buttonSize.height + 12))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rect(_ index: Int) -> NSRect {
        let totalWidth = CGFloat(actions.count) * Self.buttonSize.width
        let x = (bounds.width - totalWidth) / 2 + CGFloat(index) * Self.buttonSize.width
        return NSRect(x: x, y: (bounds.height - Self.buttonSize.height) / 2, width: Self.buttonSize.width, height: Self.buttonSize.height)
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
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                    .applying(.init(hierarchicalColor: .labelColor))) {
                let size = image.size
                image.draw(in: NSRect(x: area.midX - size.width / 2, y: area.maxY - 8 - size.height, width: size.width, height: size.height))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            (entry.title as NSString).draw(in: NSRect(x: area.minX + 2, y: area.minY + 6, width: area.width - 4, height: 15), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
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
