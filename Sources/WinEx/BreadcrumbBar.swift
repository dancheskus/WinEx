import AppKit

/// The address bar's normal face, like Windows 11 Explorer: the location's icon, then each step of
/// the path as a button, with "›" between them.
///  - a step opens that folder;
///  - "›" after a step lists its subfolders (the root's lists the drives) to jump sideways;
///  - when the path doesn't fit, the first steps fold into "…", which lists them;
///  - a click on the empty part switches to typing a path (`onEdit`).
final class BreadcrumbBar: NSView {
    struct Crumb {
        var title: String
        /// Where a click goes.
        var url: URL
        /// Folder whose subfolders "›" after this step lists (nil: nothing to list).
        var folder: URL?
    }

    var onNavigate: ((URL) -> Void)?
    var onEdit: (() -> Void)?

    private var rootIcon: NSImage?
    private var rootURL = Places.computerURL
    private var crumbs: [Crumb] = []
    private var buttons: [CrumbButton] = []

    // MARK: Content

    /// Shows the path of `location`.
    func show(_ location: Location) {
        (rootIcon, rootURL, crumbs) = Self.path(for: location)
        rebuild()
    }

    static func path(for location: Location) -> (icon: NSImage?, root: URL, crumbs: [Crumb]) {
        func symbol(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        }
        switch location {
        case .computer:
            return (symbol("desktopcomputer"), Places.computerURL, [Crumb(title: "Этот Mac", url: Places.computerURL, folder: nil)])
        case .network:
            return (symbol("network"), Places.networkURL, [Crumb(title: "Сеть", url: Places.networkURL, folder: nil)])
        case .trash:
            return (symbol("trash"), Places.trashURL, [Crumb(title: "Корзина", url: Places.trashURL, folder: nil)])
        case .tag(let name):
            return (symbol("tag"), location.url, [Crumb(title: name, url: location.url, folder: nil)])
        case .search(let request):
            return (symbol("magnifyingglass"), location.url, [Crumb(title: "Результаты поиска «\(request.text)»", url: location.url, folder: nil)])
        case .folder(let url):
            return folderPath(url)
        }
    }

    /// "Этот Mac › Macintosh HD › Пользователи › …", or "Сеть › сервер › том › …" on a network volume.
    private static func folderPath(_ url: URL) -> (icon: NSImage?, root: URL, crumbs: [Crumb]) {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeLocalizedNameKey, .volumeIsLocalKey])
        let volume = values?.volume ?? URL(fileURLWithPath: "/")
        var result: [Crumb] = []
        let network = values?.volumeIsLocal == false
        if network {
            result.append(Crumb(title: "Сеть", url: Places.networkURL, folder: nil))
            if let server = Places.serverName(ofVolume: volume) { result.append(Crumb(title: server, url: Places.networkURL, folder: nil)) }
        }
        let volumeName = values?.volumeLocalizedName ?? fm.displayName(atPath: volume.path)
        result.append(Crumb(title: volumeName, url: volume, folder: volume))
        // Each folder below the volume, with its localized name ("Пользователи", "Рабочий стол")
        let volumeParts = volume.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        var current = volume
        for part in parts.dropFirst(volumeParts.count) {
            current = current.appendingPathComponent(part)
            result.append(Crumb(title: fm.displayName(atPath: current.path), url: current, folder: current))
        }
        let icon = NSImage(systemSymbolName: network ? "network" : "desktopcomputer", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        return (icon, network ? Places.networkURL : Places.computerURL, result)
    }

    // MARK: Layout

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        needsLayout = true
    }

    override func layout() {
        super.layout()
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        let height = bounds.height - 8
        let y = (bounds.height - height) / 2
        let font = NSFont.systemFont(ofSize: 14)
        func textWidth(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16 }
        let iconWidth: CGFloat = 32, chevronWidth: CGFloat = 22, ellipsisWidth: CGFloat = 30

        // Fold the first steps into "…" until the rest fits; the last step is always shown
        var folded = 0
        func width(folding n: Int) -> CGFloat {
            var total = iconWidth + chevronWidth
            if n > 0 { total += ellipsisWidth + chevronWidth }
            for crumb in crumbs.dropFirst(n) { total += textWidth(crumb.title) + chevronWidth }
            return total
        }
        // Always leave an empty strip on the right: a click there switches to typing a path
        let typingStrip: CGFloat = 40
        while folded < crumbs.count - 1 && width(folding: folded) > bounds.width - 8 - typingStrip { folded += 1 }

        var x: CGFloat = 4
        func place(_ button: CrumbButton, width: CGFloat) {
            button.frame = NSRect(x: x, y: y, width: width, height: height)
            addSubview(button)
            buttons.append(button)
            x += width
        }
        // The location's icon: "Этот Mac" (or "Сеть"); its "›" lists the drives
        place(CrumbButton(icon: rootIcon, tip: "Этот Mac") { [weak self] _ in
            guard let self else { return }
            onNavigate?(rootURL)
        }, width: iconWidth)
        place(chevron { Self.drivesMenu(current: $0) }, width: chevronWidth)
        if folded > 0 {
            let hidden = Array(crumbs.prefix(folded))
            place(CrumbButton(text: "…", font: font, tip: "Предыдущие папки") { [weak self] button in
                self?.popUp(self?.menu(for: hidden.reversed()), under: button)
            }, width: ellipsisWidth)
            place(chevron(listing: crumbs[folded - 1].folder), width: chevronWidth)
        }
        for (n, crumb) in crumbs.enumerated().dropFirst(folded) {
            let isLast = n == crumbs.count - 1
            let available = bounds.width - 4 - x - (isLast ? chevronWidth + typingStrip : 0)
            let button = CrumbButton(text: crumb.title, font: font, tip: crumb.url.isFileURL ? crumb.url.path : crumb.title) { [weak self] _ in
                self?.onNavigate?(crumb.url)
            }
            place(button, width: max(40, min(textWidth(crumb.title), available)))
            if crumb.folder != nil { place(chevron(listing: crumb.folder, current: crumbs[safe: n + 1]?.url), width: chevronWidth) }
        }
    }

    // MARK: Menus

    private func chevron(listing folder: URL?, current: URL? = nil) -> CrumbButton {
        chevron { _ in folder.map { Self.subfolderMenu(of: $0, current: current) } ?? NSMenu() }
    }

    private func chevron(_ makeMenu: @escaping (URL?) -> NSMenu) -> CrumbButton {
        let crumbs = crumbs
        return CrumbButton(chevron: true, tip: "Другие папки") { [weak self] button in
            guard let self else { return }
            // The step after this chevron is the one to mark in the list
            let index = self.buttons.firstIndex { $0 === button }
            let next = index.flatMap { i in self.buttons.indices.contains(i + 1) ? self.buttons[i + 1].toolTip : nil }
            let current = crumbs.first { $0.url.path == next }?.url
            button.isOpen = true
            self.popUp(self.wired(makeMenu(current)), under: button)
            button.isOpen = false
        }
    }

    /// Subfolders of `folder` (not hidden, not packages), the current one ticked.
    private static func subfolderMenu(of folder: URL, current: URL?) -> NSMenu {
        let menu = NSMenu()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let children = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .filter { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { FileManager.default.displayName(atPath: $0.path).localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending }
        for child in children.prefix(300) {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: child.path), action: nil, keyEquivalent: "")
            item.representedObject = child
            item.image = smallIcon(child)
            if child.standardizedFileURL.path == current?.standardizedFileURL.path { item.state = .on }
            menu.addItem(item)
        }
        if children.isEmpty { menu.addItem(withTitle: "Нет вложенных папок", action: nil, keyEquivalent: "").isEnabled = false }
        return menu
    }

    /// The drives (and "Этот Mac"), for the root's "›".
    private static func drivesMenu(current: URL?) -> NSMenu {
        let menu = NSMenu()
        let this = NSMenuItem(title: "Этот Mac", action: nil, keyEquivalent: "")
        this.representedObject = Places.computerURL
        this.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        menu.addItem(this)
        menu.addItem(.separator())
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: volume.path), action: nil, keyEquivalent: "")
            item.representedObject = volume
            item.image = smallIcon(volume)
            if volume.standardizedFileURL.path == current?.standardizedFileURL.path { item.state = .on }
            menu.addItem(item)
        }
        return menu
    }

    /// The steps folded into "…", nearest first.
    private func menu(for hidden: [Crumb]) -> NSMenu {
        let menu = NSMenu()
        for crumb in hidden {
            let item = NSMenuItem(title: crumb.title, action: nil, keyEquivalent: "")
            item.representedObject = crumb.url
            item.image = crumb.url.isFileURL ? Self.smallIcon(crumb.url) : nil
            menu.addItem(item)
        }
        return wired(menu)
    }

    private static func smallIcon(_ url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// Every item with a URL navigates there.
    private func wired(_ menu: NSMenu) -> NSMenu {
        for item in menu.items {
            guard let url = item.representedObject as? URL else { continue }
            item.target = self
            item.action = #selector(menuNavigate(_:))
            item.representedObject = url
        }
        return menu
    }

    @objc private func menuNavigate(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onNavigate?(url) }
    }

    private func popUp(_ menu: NSMenu?, under button: NSView) {
        guard let menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
    }

    // MARK: Mouse

    /// A click beside the steps: type a path instead.
    override func mouseDown(with event: NSEvent) {
        onEdit?()
    }
}

/// One step, "›" or "…" of the breadcrumb bar: text or an icon, highlighted under the mouse.
final class CrumbButton: NSView {
    private let text: String?
    private let icon: NSImage?
    private let font: NSFont
    private let isChevron: Bool
    private let action: (CrumbButton) -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    var isOpen = false { didSet { needsDisplay = true } }

    init(text: String? = nil, icon: NSImage? = nil, font: NSFont = .systemFont(ofSize: 14), chevron: Bool = false,
         tip: String?, action: @escaping (CrumbButton) -> Void) {
        self.text = text
        self.icon = icon
        self.font = font
        self.isChevron = chevron
        self.action = action
        super.init(frame: .zero)
        toolTip = tip
    }

    convenience init(icon: NSImage?, tip: String, action: @escaping (CrumbButton) -> Void) {
        self.init(text: nil, icon: icon, tip: tip, action: action)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action(self) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isOpen {
            NSColor.labelColor.withAlphaComponent(isOpen ? 0.14 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if isChevron {
            let symbol = NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                    .applying(.init(hierarchicalColor: .secondaryLabelColor)))
            symbol.map { draw($0) }
        } else if let icon {
            let tinted = icon.withSymbolConfiguration(.init(hierarchicalColor: .secondaryLabelColor)) ?? icon
            draw(tinted)
        } else if let text {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let size = (text as NSString).size(withAttributes: attributes)
            let rect = NSRect(x: 8, y: (bounds.height - size.height) / 2, width: bounds.width - 16, height: size.height)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: attributes.merging([.paragraphStyle: paragraph]) { $1 })
        }
    }

    private func draw(_ image: NSImage) {
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }
}
