import AppKit
import os

/// Finder's «Импортировать с iPhone» (Continuity Camera): AppKit fills the item with the
/// nearby devices and their actions (take a photo, scan documents, add a sketch); what the device
/// sends comes back on a pasteboard and is saved as a file in the folder the menu was for.
@MainActor
final class DeviceImport: NSObject, @preconcurrency NSServicesMenuRequestor {
    static let shared = DeviceImport()
    /// `log show --predicate 'subsystem == "dev.winex.WinEx" && category == "deviceImport"' --info`
    static let log = Logger(subsystem: "dev.winex.WinEx", category: "deviceImport")

    /// What a device sends: a scan as PDF, a photo as HEIC or JPEG, a sketch as PNG.
    static let types: [NSPasteboard.PasteboardType] = [.pdf, .init("public.heic"), .init("public.jpeg"), .png, .tiff]

    /// The folder the picture goes into (the one whose menu offered the import).
    private var destination: URL?

    /// Once at launch: AppKit asks for a requestor only for types an app has registered.
    static func register() {
        NSApp.registerServicesMenuSendTypes([], returnTypes: types)
        // As a WinEx menu opens, AppKit has filled its (hidden) item: the devices go into WinEx's row
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated { takeOver(in: menu) }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { taken = nil }
        }
    }

    static let rowIdentifier = NSUserInterfaceItemIdentifier("winexImportFromDevice")
    /// AppKit's items taken out of the menus: their devices' actions target what they own.
    private static var retired: [NSMenuItem] = []
    private static var hiddenWatch: NSKeyValueObservation?
    /// What AppKit put in its item as the menu began to open, for the row of a menu its
    /// delegate builds only then (`menuNeedsUpdate`, after AppKit filled the old build's item).
    private static var taken: (title: String, entries: [NSMenuItem])?
    private static var forwarding: [ObjectIdentifier: (target: AnyObject?, action: Selector?)] = [:]

    @objc private func forward(_ sender: NSMenuItem) {
        guard let original = Self.forwarding[ObjectIdentifier(sender)], let action = original.action else {
            return Self.log.error("clicked «\(sender.title, privacy: .public)»: no action kept")
        }
        Self.log.info("clicked «\(sender.title, privacy: .public)»: \(NSStringFromSelector(action), privacy: .public) to \(String(describing: original.target), privacy: .public), destination \(self.destination?.path ?? "none", privacy: .public)")
        // AppKit puts its sheet on the key window
        if onDesktop { helperWindow?.makeKeyAndOrderFront(nil) }
        let sent = NSApp.sendAction(action, to: original.target, from: sender)
        Self.log.info("sent: \(sent, privacy: .public)")
        if !sent { helperWindow?.orderOut(nil) }
    }

    /// Adds «Импортировать с iPhone» to a context menu: AppKit's item, hidden, and WinEx's row.
    /// AppKit serves only an item that was in the main menu from the start (a copy of it works;
    /// one made later stays grey), fills it only as its menu begins to open, and draws it its own
    /// way, ignoring WinEx's look — so it's kept out of sight, and what AppKit put in it (the
    /// devices near and their actions, the name «Импортировать с iPhone») moves into WinEx's row.
    /// No device near: the row stays hidden.
    static func addItems(to menu: NSMenu, into directory: URL) {
        shared.destination = directory
        // AppKit would also list the devices at the menu's end, as a context menu's plug-in section
        menu.allowsContextMenuPlugIns = false
        // For the next time the menu opens (this one is past AppKit's filling)
        seed(menu)
        let row = NSMenuItem(title: L("Импортировать с iPhone"), action: nil, keyEquivalent: "")
        row.identifier = rowIdentifier
        row.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        row.submenu = NSMenu()
        row.isHidden = true
        menu.addItem(row)
        if let taken { fill(row, title: taken.title, entries: taken.entries) }
    }

    /// AppKit's item, hidden, in a menu built by its delegate as it opens: it's there to be filled
    /// the first time (call when the menu is made).
    static func seed(_ menu: NSMenu) {
        // AppKit lists the devices at a context menu's end (a plug-in section, «iPhone (…)» with its
        // actions) whenever something could take a picture: in a file's menu too. Only WinEx's row.
        menu.allowsContextMenuPlugIns = false
        guard let managed = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first(where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier })?.copy() as? NSMenuItem else { return }
        managed.isHidden = true
        menu.addItem(managed)
        // AppKit shows it once it has filled it (when the menu isn't built at the last moment)
        hiddenWatch = managed.observe(\.isHidden, options: [.new]) { [weak menu] item, _ in
            guard !item.isHidden else { return }
            MainActor.assumeIsolated { if let menu { takeOver(in: menu) } }
        }
    }

    private static func takeOver(in menu: NSMenu) {
        guard let managed = menu.items.first(where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier }) else { return }
        let entries = managed.submenu?.items ?? []
        menu.removeItem(managed)
        retired = [managed]
        log.info("menu opening: AppKit's item has \(entries.count, privacy: .public) entries")
        guard entries.contains(where: { !$0.isSeparatorItem }) else { taken = nil; return }
        managed.submenu?.removeAllItems()
        // The actions go through WinEx, which holds their target (a menu holds it weakly: gone
        // with AppKit's item, the click did nothing)
        forwarding = [:]
        for entry in entries where entry.action != nil {
            forwarding[ObjectIdentifier(entry)] = (entry.target, entry.action)
            entry.target = shared
            entry.action = #selector(forward(_:))
        }
        // (AppKit ends the list with a separator)
        let list = Array(entries.reversed().drop(while: \.isSeparatorItem).reversed())
        let title = managed.title.isEmpty || managed.title.hasPrefix("<<") ? L("Импортировать с iPhone") : managed.title
        taken = (title, list)
        if let row = menu.items.first(where: { $0.identifier == rowIdentifier }) {
            fill(row, title: title, entries: list)
            MenuStyle.decorate(menu)
        }
    }

    private static func fill(_ row: NSMenuItem, title: String, entries: [NSMenuItem]) {
        guard let submenu = row.submenu else { return }
        submenu.removeAllItems()
        for entry in entries {
            entry.menu?.removeItem(entry)
            submenu.addItem(entry)
        }
        row.title = title
        // Styled again with its name (WinEx's look is made once per item)
        row.attributedTitle = nil
        row.view = nil
        row.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        row.isHidden = false
    }

    /// The main menu's item (in «Файл»), the one AppKit serves.
    nonisolated static func mainMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("Импортировать с iPhone"), action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        return item
    }

    /// For a responder's `validRequestor(forSendType:returnType:)`: the import, into `directory`,
    /// when the responder has a folder to save into and nothing is being sent.
    /// AppKit shows its sheet («Снимите фото, используя iPhone») on the requestor's window, so the
    /// requestor is a view: a dot in the middle of `view`'s window.
    static func requestor(into directory: URL?, in view: NSView?, sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard let directory, sendType == nil, let returnType, types.contains(returnType) || returnType.rawValue == "NeXT TIFF v4.0 pasteboard type" else { return nil }
        log.info("asked for a requestor (\(returnType.rawValue, privacy: .public)): \(directory.path, privacy: .public), window \(view?.window.map { String(describing: type(of: $0)) } ?? "none", privacy: .public)")
        shared.destination = directory
        guard let window = view?.window, var content = window.contentView else { return shared }
        // The sheet darkens its window: on the desktop (a window as big as the screen) it goes on a
        // small clear window in the middle of the screen instead
        shared.onDesktop = window.level.rawValue < NSWindow.Level.normal.rawValue
        if shared.onDesktop, let helper = shared.helper(on: window.screen), let helperContent = helper.contentView { content = helperContent }
        let anchor = shared.anchor
        if anchor.superview !== content { content.addSubview(anchor) }
        anchor.frame = NSRect(x: content.bounds.midX, y: content.bounds.midY, width: 1, height: 1)
        return anchor
    }

    private var onDesktop = false

    /// Clear and borderless, but it can be the key window: AppKit puts its sheet on the key window,
    /// and when the picture comes, asks the key window where it goes.
    private final class HelperWindow: NSWindow {
        override var canBecomeKey: Bool { true }

        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
            DeviceImport.requestor(into: DeviceImport.shared.destination, in: contentView, sendType: sendType, returnType: returnType)
                ?? super.validRequestor(forSendType: sendType, returnType: returnType)
        }
    }
    private var helperWindow: NSWindow?

    private func helper(on screen: NSScreen?) -> NSWindow? {
        guard let area = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let window = helperWindow ?? {
            let window = HelperWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .floating
            window.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { window?.orderOut(nil) }
            }
            helperWindow = window
            return window
        }()
        window.setFrame(NSRect(x: area.midX - 260, y: area.maxY - area.height / 3, width: 520, height: 2), display: false)
        return window
    }

    private lazy var anchor = Anchor(frame: .zero)

    /// The requestor AppKit sees; what comes back is saved by `DeviceImport`.
    private final class Anchor: NSView, @preconcurrency NSServicesMenuRequestor {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
        func readSelection(from pboard: NSPasteboard) -> Bool { DeviceImport.shared.readSelection(from: pboard) }
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        Self.log.info("received \(pboard.types?.map(\.rawValue) ?? [], privacy: .public)")
        helperWindow?.orderOut(nil)
        guard let directory = destination, let type = pboard.availableType(from: Self.types),
              var data = pboard.data(forType: type) else { return false }
        let ext: String
        let kind: String
        switch type {
        case .pdf: (ext, kind) = ("pdf", L("Скан"))
        case .png: (ext, kind) = ("png", L("Набросок"))
        case .tiff:
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return false }
            data = png
            (ext, kind) = ("png", L("Снимок"))
        default: (ext, kind) = (type.rawValue == "public.heic" ? "heic" : "jpeg", L("Снимок"))
        }
        let url = FileOps.newItemURL(named: "\(kind) \(Self.stamp.string(from: Date())).\(ext)", in: directory)
        return (try? data.write(to: url, options: .withoutOverwriting)) != nil
    }

    /// Like a screenshot's name: «Снимок 2026-10-17 в 14.03.12».
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd '\(L("в"))' HH.mm.ss"
        return formatter
    }()
}
