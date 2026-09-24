import AppKit

/// Draws desktop icons in place of Finder (Finder's desktop is off in replacement mode).
/// Double-clicking a folder opens it in WinEx.
@MainActor
final class DesktopController {
    private var window: DesktopWindow?
    private let desktopView = DesktopView()
    private var screenObserver: NSObjectProtocol?

    func show() {
        guard window == nil else { return }
        let window = DesktopWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = desktopView
        self.window = window
        updateFrame()
        desktopView.start()
        window.orderFront(nil)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrame() }
        }
    }

    func hide() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        desktopView.stop()
        window?.orderOut(nil)
        window = nil
    }

    /// Covers the main screen; icons are laid out inside the visible frame (no menu bar / Dock).
    private func updateFrame() {
        guard let window, let screen = NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: true)
        let frame = screen.frame, visible = screen.visibleFrame
        desktopView.iconArea = NSRect(x: visible.minX - frame.minX, y: frame.maxY - visible.maxY,
                                      width: visible.width, height: visible.height)
    }
}

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DesktopView: NSView, NSDraggingSource {
    private static let cellSize = NSSize(width: 100, height: 106)

    var iconArea: NSRect = .zero { didSet { needsDisplay = true } }

    private let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    private var items: [FileItem] = []
    private var selection = Set<Int>()
    private var watcher: DirectoryWatcher?
    private var mouseDownIndex: Int?
    private var mouseDownPoint = NSPoint.zero
    private var dragStarted = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func start() {
        reload()
        watcher = DirectoryWatcher(url: desktopURL) { [weak self] in self?.reload() }
    }

    func stop() {
        watcher = nil
    }

    private func reload() {
        let selectedPaths = Set(selection.map { items[$0].url.path })
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: desktopURL, includingPropertiesForKeys: FileItem.keys, options: [.skipsHiddenFiles])) ?? []
        items = urls.map(FileItem.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = Set(items.indices.filter { selectedPaths.contains(items[$0].url.path) })
        needsDisplay = true
    }

    // MARK: - Geometry (columns fill from the top-right corner, like macOS)

    private func cellRect(at index: Int) -> NSRect {
        let size = Self.cellSize
        let rows = max(1, Int((iconArea.height - 16) / size.height))
        let column = index / rows, row = index % rows
        return NSRect(x: iconArea.maxX - CGFloat(column + 1) * size.width - 12,
                      y: iconArea.minY + 12 + CGFloat(row) * size.height,
                      width: size.width, height: size.height)
    }

    private func iconRect(in cell: NSRect) -> NSRect {
        NSRect(x: cell.midX - 32, y: cell.minY + 4, width: 64, height: 64)
    }

    private func labelRect(in cell: NSRect) -> NSRect {
        NSRect(x: cell.minX + 2, y: cell.minY + 72, width: cell.width - 4, height: 32)
    }

    private func index(at point: NSPoint) -> Int? {
        items.indices.first { i in
            let cell = cellRect(at: i)
            return iconRect(in: cell).insetBy(dx: -4, dy: -4).contains(point) || labelRect(in: cell).contains(point)
        }
    }

    // MARK: - Drawing

    private func labelAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        return [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph, .shadow: shadow]
    }

    override func draw(_ dirtyRect: NSRect) {
        // Almost-transparent fill so clicks on empty desktop reach us (for deselection / context menu)
        NSColor(white: 0, alpha: 0.005).setFill()
        dirtyRect.fill()

        let attributes = labelAttributes()
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        for (i, item) in items.enumerated() {
            let cell = cellRect(at: i)
            guard cell.intersects(dirtyRect) else { continue }
            let iconRect = iconRect(in: cell)
            let labelRect = labelRect(in: cell)
            let label = NSAttributedString(string: item.name, attributes: attributes)

            if selection.contains(i) {
                NSColor.white.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: iconRect.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6).fill()
                let textBounds = label.boundingRect(with: labelRect.size, options: options)
                let highlight = NSRect(x: labelRect.midX - textBounds.width / 2 - 4, y: labelRect.minY - 1,
                                       width: textBounds.width + 8, height: textBounds.height + 2)
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: highlight, xRadius: 4, yRadius: 4).fill()
            }
            item.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            label.draw(with: labelRect, options: options)
        }
    }

    // MARK: - Mouse & keyboard

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        dragStarted = false
        mouseDownIndex = index(at: point)
        if let i = mouseDownIndex {
            if event.modifierFlags.contains(.command) {
                if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            } else if !selection.contains(i) {
                selection = [i]
            }
            if event.clickCount == 2 { openSelection() }
        } else {
            selection = []
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownIndex != nil, !dragStarted else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        dragStarted = true
        let draggingItems = selection.sorted().map { i -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: items[i].url as NSURL)
            item.setDraggingFrame(iconRect(in: cellRect(at: i)), contents: items[i].icon)
            return item
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownIndex = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic]
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (36, []), (76, []): openSelection()
        case (51, [.command]): trashSelection()
        case (0, [.command]): selection = Set(items.indices); needsDisplay = true
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if let i = index(at: point) {
            if !selection.contains(i) { selection = [i]; needsDisplay = true }
            add("Открыть", #selector(openSelectionAction(_:)))
            add("Копировать путь", #selector(copyPathAction(_:)))
            menu.addItem(.separator())
            add("Переместить в корзину", #selector(trashAction(_:)))
        } else {
            selection = []
            needsDisplay = true
            add("Новая папка", #selector(newFolderAction(_:)))
            add("Открыть «Рабочий стол» в WinEx", #selector(openDesktopAction(_:)))
            menu.addItem(.separator())
            menu.addItem(withTitle: "Настройки WinEx…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
                .target = AppDelegate.shared
        }
        return menu
    }

    private var selectedURLs: [URL] { selection.sorted().map { items[$0].url } }

    private func openSelection() {
        selectedURLs.forEach { AppDelegate.shared.open($0) }
    }

    private func trashSelection() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        FileOps.trash(urls)
        selection = []
    }

    @objc private func openSelectionAction(_ sender: Any?) { openSelection() }
    @objc private func copyPathAction(_ sender: Any?) { FileOps.copyPaths(selectedURLs) }
    @objc private func trashAction(_ sender: Any?) { trashSelection() }
    @objc private func openDesktopAction(_ sender: Any?) { AppDelegate.shared.openWindow(at: desktopURL) }

    @objc private func newFolderAction(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: FileOps.newFolderURL(in: desktopURL), withIntermediateDirectories: false)
    }
}
