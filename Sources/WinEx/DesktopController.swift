import AppKit
import Quartz

/// Draws desktop icons in place of Finder (Finder's desktop is off in replacement mode).
/// Double-clicking a folder opens it in WinEx; icons can be moved, arranged and sorted like on Windows.
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

final class DesktopView: NSView, NSDraggingSource, NSTextFieldDelegate, NSMenuItemValidation,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Screen area not covered by the menu bar and Dock (view coordinates, y from the top).
    var iconArea: NSRect = .zero { didSet { if iconArea != oldValue { relayout() } } }

    private let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    private lazy var layout = DesktopLayout(desktop: desktopURL, screenSize: window?.frame.size ?? NSScreen.screens.first?.frame.size ?? .zero)
    /// Desktop widgets (Notification Center windows above the icons); icons are kept out of them, like Finder does.
    private var widgetRects: [NSRect] = []
    private var items: [FileItem] = []
    /// Icon centers in view coordinates, parallel to `items`.
    private var centers: [CGPoint] = []
    private var selection = Set<Int>() {
        didSet { if selection != oldValue { QuickLook.selectionChanged(in: self) } }
    }
    private var watcher: DirectoryWatcher?

    // Mouse tracking
    private var mouseDownIndex: Int?
    private var mouseDownPoint = NSPoint.zero
    private var dragStarted = false
    private var collapseOnMouseUp: Int?
    private var rubberBand: NSRect?
    private var rubberBandBase = Set<Int>()

    // Dragging icons
    private var draggedNames: [String] = []
    private var dragOrigin = NSPoint.zero
    private var dropTarget: Int?

    // Context menu / rename
    private var menuPoint: NSPoint?
    private var renameField: NSTextField?
    private var renamingName: String?
    private var renameCancelled = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func start() {
        registerForDraggedTypes([.fileURL])
        reload()
        watcher = DirectoryWatcher(url: desktopURL) { [weak self] in self?.reload() }
        NotificationCenter.default.addObserver(forName: FileClipboard.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    func stop() {
        endRename()
        watcher = nil
    }

    // MARK: - Items and layout

    private func reload() {
        let selectedNames = Set(selection.map { name(of: $0) })
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: desktopURL, includingPropertiesForKeys: FileItem.keys, options: [.skipsHiddenFiles])) ?? []
        items = urls.map(FileItem.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        layout.prune(keeping: Set(items.map { $0.url.lastPathComponent }))
        selection = Set(items.indices.filter { selectedNames.contains(name(of: $0)) })
        relayout()
    }

    private func name(of index: Int) -> String {
        items[index].url.lastPathComponent
    }

    private func index(named name: String) -> Int? {
        items.firstIndex { $0.url.lastPathComponent == name }
    }

    /// Places every icon: stored positions, free grid cells for new files, or a sorted grid with auto-arrange.
    private func relayout() {
        guard bounds.width > 0, iconArea.width > 0 else { return }
        widgetRects = Self.widgetFrames(in: window)
        centers = Array(repeating: .zero, count: items.count)
        if layout.autoArrange {
            arrange(by: layout.sortKey)
            return
        }
        var placed: [CGPoint] = []
        var unplaced: [Int] = []
        var underWidgets: [Int] = []
        for i in items.indices {
            if let fraction = layout.position(for: name(of: i)) {
                centers[i] = clamp(CGPoint(x: fraction.x * bounds.width, y: fraction.y * bounds.height))
                if isUnderWidget(centers[i]) { underWidgets.append(i) } else { placed.append(centers[i]) }
            } else {
                unplaced.append(i)
            }
        }
        // Shown next to the widget; the stored position is kept in case the widget goes away
        for i in underWidgets {
            centers[i] = nearestFreeCell(to: centers[i], occupied: placed)
            placed.append(centers[i])
        }
        for i in unplaced {
            centers[i] = firstFreeCell(occupied: placed)
            placed.append(centers[i])
            storePosition(of: i)
        }
        if !unplaced.isEmpty { layout.save() }
        needsDisplay = true
    }

    private func storePosition(of index: Int) {
        let center = centers[index]
        layout.setPosition(CGPoint(x: center.x / bounds.width, y: center.y / bounds.height), for: name(of: index))
    }

    private func storeAllPositions() {
        items.indices.forEach(storePosition)
        layout.save()
        needsDisplay = true
    }

    // MARK: Geometry

    private var iconSide: CGFloat { layout.iconSize.iconSide }
    private var cellSize: NSSize { layout.iconSize.cellSize }

    private func iconRect(at center: CGPoint) -> NSRect {
        NSRect(x: center.x - iconSide / 2, y: center.y - iconSide / 2, width: iconSide, height: iconSide)
    }

    private func labelRect(at center: CGPoint) -> NSRect {
        NSRect(x: center.x - cellSize.width / 2 + 2, y: center.y + iconSide / 2 + 4, width: cellSize.width - 4, height: 32)
    }

    private func hitRect(_ index: Int) -> NSRect {
        iconRect(at: centers[index]).insetBy(dx: -4, dy: -4).union(labelRect(at: centers[index]))
    }

    private func index(at point: NSPoint) -> Int? {
        guard layout.showIcons else { return nil }
        // Topmost (last drawn) first
        return items.indices.reversed().first { hitRect($0).contains(point) }
    }

    /// Keeps an icon (and its label) inside the visible desktop area.
    private func clamp(_ point: CGPoint) -> CGPoint {
        let minX = iconArea.minX + cellSize.width / 2, maxX = iconArea.maxX - cellSize.width / 2
        let minY = iconArea.minY + iconSide / 2 + 4, maxY = iconArea.maxY - iconSide / 2 - 38
        return CGPoint(x: min(max(point.x, minX), max(minX, maxX)), y: min(max(point.y, minY), max(minY, maxY)))
    }

    /// Grid cells, filled in columns from the top-right corner (where macOS keeps desktop icons).
    private func gridCells() -> [CGPoint] {
        let columns = max(1, Int((iconArea.width - 24) / cellSize.width))
        let rows = max(1, Int((iconArea.height - 24) / cellSize.height))
        var cells: [CGPoint] = []
        for column in 0..<columns {
            for row in 0..<rows {
                cells.append(CGPoint(x: iconArea.maxX - 12 - cellSize.width * (CGFloat(column) + 0.5),
                                     y: iconArea.minY + 12 + iconSide / 2 + 4 + cellSize.height * CGFloat(row)))
            }
        }
        return cells
    }

    private func isFree(_ cell: CGPoint, occupied: [CGPoint]) -> Bool {
        !isUnderWidget(cell)
            && !occupied.contains { abs($0.x - cell.x) < cellSize.width * 0.8 && abs($0.y - cell.y) < cellSize.height * 0.8 }
    }

    private func isUnderWidget(_ center: CGPoint) -> Bool {
        let cell = NSRect(x: center.x - cellSize.width / 2, y: center.y - iconSide / 2, width: cellSize.width, height: cellSize.height - 8)
        return widgetRects.contains { $0.intersects(cell) }
    }

    /// Frames of desktop widgets in view coordinates (window list bounds are top-left based, like this view).
    private static func widgetFrames(in window: NSWindow?) -> [NSRect] {
        guard let window, let screen = window.screen ?? NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let screenTop = NSScreen.screens.first.map { $0.frame.maxY } ?? 0
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer > desktopLevel, layer < 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.notificationcenterui",
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            // Window-list y is measured from the top of the primary screen
            return NSRect(x: rect.minX - screen.frame.minX, y: rect.minY - (screenTop - screen.frame.maxY),
                          width: rect.width, height: rect.height)
        }
    }

    private func firstFreeCell(occupied: [CGPoint]) -> CGPoint {
        let cells = gridCells()
        return cells.first { isFree($0, occupied: occupied) } ?? cells.last ?? .zero
    }

    private func nearestFreeCell(to point: CGPoint, occupied: [CGPoint]) -> CGPoint {
        gridCells().filter { isFree($0, occupied: occupied) }
            .min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? clamp(point)
    }

    // MARK: Arranging

    private func arrange(by key: DesktopSortKey) {
        let order = items.indices.sorted { a, b in
            let x = items[a], y = items[b]
            switch key {
            case .name: break
            case .size:
                if x.isFolder != y.isFolder { return x.isFolder }
                if (x.size ?? 0) != (y.size ?? 0) { return (x.size ?? 0) < (y.size ?? 0) }
            case .type:
                if x.isFolder != y.isFolder { return x.isFolder }
                let result = x.typeDescription.localizedStandardCompare(y.typeDescription)
                if result != .orderedSame { return result == .orderedAscending }
            case .date:
                // Newest first
                if x.modified != y.modified { return (x.modified ?? .distantPast) > (y.modified ?? .distantPast) }
            }
            return x.name.localizedStandardCompare(y.name) == .orderedAscending
        }
        let cells = gridCells()
        for (n, i) in order.enumerated() {
            centers[i] = cells.indices.contains(n) ? cells[n] : (cells.last ?? .zero)
        }
        storeAllPositions()
    }

    /// Moves every icon to the nearest free grid cell ("Align icons to grid").
    private func snapAllToGrid() {
        var occupied: [CGPoint] = []
        let order = items.indices.sorted { centers[$0].x != centers[$1].x ? centers[$0].x > centers[$1].x : centers[$0].y < centers[$1].y }
        for i in order {
            centers[i] = nearestFreeCell(to: centers[i], occupied: occupied)
            occupied.append(centers[i])
        }
        storeAllPositions()
    }

    /// Moves dropped icons by the drag distance, snapping to free cells when aligning to the grid.
    private func moveIcons(named names: [String], by delta: CGSize) {
        guard !layout.autoArrange else { return }  // auto-arranged icons snap back, like on Windows
        let moving = Set(names)
        var occupied = items.indices.filter { !moving.contains(name(of: $0)) }.map { centers[$0] }
        for i in items.indices where moving.contains(name(of: i)) {
            var target = clamp(CGPoint(x: centers[i].x + delta.width, y: centers[i].y + delta.height))
            if layout.alignToGrid { target = nearestFreeCell(to: target, occupied: occupied) }
            centers[i] = target
            occupied.append(target)
        }
        storeAllPositions()
    }

    /// Where a new or dropped file should appear when it lands at `point`.
    private func placement(near point: CGPoint, occupied: [CGPoint]) -> CGPoint {
        layout.alignToGrid || layout.autoArrange ? nearestFreeCell(to: point, occupied: occupied) : clamp(point)
    }

    private func setPlacement(_ point: CGPoint, forName name: String) {
        layout.setPosition(CGPoint(x: point.x / bounds.width, y: point.y / bounds.height), for: name)
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
        return [.font: NSFont.systemFont(ofSize: layout.iconSize == .small ? 11 : 12, weight: .medium),
                .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow]
    }

    override func draw(_ dirtyRect: NSRect) {
        // Almost-transparent fill so clicks on empty desktop reach us (context menu, rubber band)
        NSColor(white: 0, alpha: 0.005).setFill()
        dirtyRect.fill(using: .copy)

        if layout.showIcons {
            let attributes = labelAttributes()
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            for (i, item) in items.enumerated() where hitRect(i).insetBy(dx: -4, dy: -4).intersects(dirtyRect) {
                let iconRect = iconRect(at: centers[i])
                let labelRect = labelRect(at: centers[i])
                let isRenaming = renamingName == name(of: i)
                let label = NSAttributedString(string: item.name, attributes: attributes)

                if selection.contains(i) || dropTarget == i {
                    NSColor.white.withAlphaComponent(dropTarget == i ? 0.35 : 0.2).setFill()
                    NSBezierPath(roundedRect: iconRect.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6).fill()
                }
                if selection.contains(i) && !isRenaming {
                    let textBounds = label.boundingRect(with: labelRect.size, options: options)
                    let highlight = NSRect(x: labelRect.midX - textBounds.width / 2 - 4, y: labelRect.minY - 1,
                                           width: textBounds.width + 8, height: textBounds.height + 2)
                    NSColor.selectedContentBackgroundColor.setFill()
                    NSBezierPath(roundedRect: highlight, xRadius: 4, yRadius: 4).fill()
                }
                let alpha = FileClipboard.shared.isCut(item.url) ? FileListViewController.cutAlpha : 1
                item.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: alpha,
                               respectFlipped: true, hints: nil)
                if !isRenaming { label.draw(with: labelRect, options: options) }
            }
        }

        if let rubberBand {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).setFill()
            rubberBand.fill(using: .sourceOver)
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.8).setStroke()
            NSBezierPath(rect: rubberBand.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        endRename()
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let toggles = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        mouseDownPoint = point
        dragStarted = false
        collapseOnMouseUp = nil
        mouseDownIndex = index(at: point)

        if let i = mouseDownIndex {
            if toggles {
                if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            } else if selection.contains(i) {
                if selection.count > 1 { collapseOnMouseUp = i }
            } else {
                selection = [i]
            }
            if event.clickCount == 2 && !toggles { openSelection() }
        } else {
            rubberBandBase = toggles ? selection : []
            selection = rubberBandBase
            rubberBand = NSRect(origin: point, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if rubberBand != nil {
            let rect = NSRect(x: min(point.x, mouseDownPoint.x), y: min(point.y, mouseDownPoint.y),
                              width: abs(point.x - mouseDownPoint.x), height: abs(point.y - mouseDownPoint.y))
            rubberBand = rect
            selection = rubberBandBase.union(items.indices.filter { layout.showIcons && hitRect($0).intersects(rect) })
            needsDisplay = true
            return
        }
        guard mouseDownIndex != nil, !dragStarted,
              hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        dragStarted = true
        collapseOnMouseUp = nil
        let dragged = selection.sorted()
        draggedNames = dragged.map(name(of:))
        dragOrigin = mouseDownPoint
        let draggingItems = dragged.map { i -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: items[i].url as NSURL)
            item.setDraggingFrame(iconRect(at: centers[i]), contents: items[i].icon)
            return item
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted, let i = collapseOnMouseUp { selection = [i] }
        rubberBand = nil
        mouseDownIndex = nil
        collapseOnMouseUp = nil
        needsDisplay = true
    }

    // MARK: - Dragging source

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic, .delete] : [.copy, .move, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dropped on the Trash in the Dock
        if operation == .delete { FileOps.trash(draggedNames.map { desktopURL.appendingPathComponent($0) }) }
        draggedNames = []
    }

    // MARK: - Dragging destination (moving icons, files dropped from windows, drops onto folders)

    private func isOwnDrag(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as AnyObject?) === self
    }

    private func folderIndex(at point: NSPoint, excluding names: [String]) -> Int? {
        guard let i = index(at: point), items[i].isFolder, !names.contains(name(of: i)) else { return nil }
        return i
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let own = isOwnDrag(sender)
        let target = folderIndex(at: point, excluding: own ? draggedNames : [])
        if target != dropTarget {
            dropTarget = target
            needsDisplay = true
        }
        if let target {
            let operation = FileDrop.operation(for: sender, into: items[target].url)
            if operation != [] { return operation }
        }
        if own { return .move }
        let operation = FileDrop.operation(for: sender, into: desktopURL)
        // Files already on the desktop (e.g. from a window showing ~/Desktop) are just repositioned
        return operation == [] ? .move : operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let target = dropTarget
        dropTarget = nil
        needsDisplay = true

        if let target, FileDrop.perform(sender, into: items[target].url) { return true }
        if isOwnDrag(sender) {
            moveIcons(named: draggedNames, by: CGSize(width: point.x - dragOrigin.x, height: point.y - dragOrigin.y))
            return true
        }

        // Files from elsewhere appear where they were dropped
        let urls = FileDrop.urls(sender)
        var occupied = centers
        for (n, url) in urls.enumerated() {
            let spot = placement(near: CGPoint(x: point.x + CGFloat(n) * 16, y: point.y + CGFloat(n) * 16), occupied: occupied)
            occupied.append(spot)
            setPlacement(spot, forName: url.lastPathComponent)
        }
        layout.save()
        if !FileDrop.perform(sender, into: desktopURL) { relayout() }
        return true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (36, []), (76, []): openSelection()
        case (51, [.command]): trashSelection()
        case (0, [.command]): selection = Set(items.indices); needsDisplay = true
        case (120, []): if let i = selection.sorted().first { beginRename(i) }   // F2
        case (53, []): selection = []; needsDisplay = true                           // Esc
        case (49, []): if !selection.isEmpty { QuickLook.toggle(for: self) }                    // Space
        case (123, []), (124, []), (125, []), (126, []): moveSelection(keyCode: event.keyCode)
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        endRename()
        let point = convert(event.locationInWindow, from: nil)
        menuPoint = point
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, to menu: NSMenu = menu, state: Bool? = nil, tag: Int = 0) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            if let state { item.state = state ? .on : .off }
        }

        if let i = index(at: point) {
            if !selection.contains(i) { selection = [i]; needsDisplay = true }
            add("Открыть", #selector(openSelectionAction(_:)))
            add("Быстрый просмотр", #selector(quickLookAction(_:)))
            if let openWith = OpenWithMenu.item(for: selectedURLs) { menu.addItem(openWith) }
            menu.addItem(.separator())
            add("Вырезать", #selector(cut(_:)))
            add("Копировать", #selector(copy(_:)))
            add("Копировать путь", #selector(copyPathAction(_:)))
            menu.addItem(.separator())
            add("Переименовать", #selector(renameAction(_:)))
            add("Переместить в корзину", #selector(trashAction(_:)))
            return menu
        }

        selection = []
        needsDisplay = true

        let viewMenu = NSMenu()
        for size in DesktopIconSize.allCases {
            add(size.title, #selector(setIconSize(_:)), to: viewMenu, state: layout.iconSize == size, tag: size.rawValue)
        }
        viewMenu.addItem(.separator())
        add("Упорядочить значки автоматически", #selector(toggleAutoArrange(_:)), to: viewMenu, state: layout.autoArrange)
        add("Выровнять значки по сетке", #selector(toggleAlignToGrid(_:)), to: viewMenu, state: layout.alignToGrid)
        viewMenu.addItem(.separator())
        add("Отображать значки рабочего стола", #selector(toggleShowIcons(_:)), to: viewMenu, state: layout.showIcons)
        menu.addItem(withTitle: "Вид", action: nil, keyEquivalent: "").submenu = viewMenu

        let sortMenu = NSMenu()
        for (n, key) in DesktopSortKey.allCases.enumerated() {
            add(key.title, #selector(sortBy(_:)), to: sortMenu, state: layout.autoArrange && layout.sortKey == key ? true : nil, tag: n)
        }
        menu.addItem(withTitle: "Сортировка", action: nil, keyEquivalent: "").submenu = sortMenu
        add("Обновить", #selector(refreshAction(_:)))
        menu.addItem(.separator())
        add("Вставить", #selector(paste(_:)))
        menu.addItem(.separator())
        menu.addItem(NewItemTemplate.menuItem(target: self, action: #selector(createNewItem(_:))))
        menu.addItem(.separator())
        add("Открыть «Рабочий стол» в WinEx", #selector(openDesktopAction(_:)))
        add("Обои…", #selector(openWallpaperSettings(_:)))
        menu.addItem(withTitle: "Настройки WinEx…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
            .target = AppDelegate.shared
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paste(_:)): return FileClipboard.shared.canPaste
        case #selector(cut(_:)), #selector(copy(_:)): return !selection.isEmpty
        default: return true
        }
    }

    // MARK: - Actions

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
    @objc private func quickLookAction(_ sender: Any?) { QuickLook.toggle(for: self) }

    /// Arrow keys pick the nearest icon in that direction (icons are freely placed, so by geometry).
    private func moveSelection(keyCode: UInt16) {
        guard layout.showIcons, !items.isEmpty else { return }
        guard let current = selection.sorted().first else {
            selection = [0]
            needsDisplay = true
            return
        }
        let from = centers[current]
        let candidates = items.indices.filter { i in
            let dx = centers[i].x - from.x, dy = centers[i].y - from.y
            switch keyCode {
            case 123: return dx < -1 && abs(dy) <= abs(dx)   // ←
            case 124: return dx > 1 && abs(dy) <= abs(dx)    // →
            case 126: return dy < -1 && abs(dx) <= abs(dy)   // ↑
            default: return dy > 1 && abs(dx) <= abs(dy)     // ↓
            }
        }
        guard let next = candidates.min(by: {
            hypot(centers[$0].x - from.x, centers[$0].y - from.y) < hypot(centers[$1].x - from.x, centers[$1].y - from.y)
        }) else { return }
        selection = [next]
        needsDisplay = true
    }

    // MARK: - Quick Look (space)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { QuickLook.accepts(self) }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.detach(panel, from: self)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        QuickLook.forward(event, to: self, panel: panel)
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let window, let url = item?.previewItemURL, let i = items.firstIndex(where: { $0.url.path == url.path }) else { return .zero }
        return window.convertToScreen(convert(iconRect(at: centers[i]), to: nil))
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item?.previewItemURL else { return nil }
        return items.first { $0.url.path == url.path }?.icon
    }
    @objc private func copyPathAction(_ sender: Any?) { FileOps.copyPaths(selectedURLs) }
    @objc private func trashAction(_ sender: Any?) { trashSelection() }
    @objc private func refreshAction(_ sender: Any?) { reload() }
    @objc private func openDesktopAction(_ sender: Any?) { AppDelegate.shared.openWindow(at: desktopURL) }

    // ⌘X / ⌘C / ⌘V arrive here through the main menu when the desktop is focused
    @objc func cut(_ sender: Any?) { FileClipboard.shared.cut(selectedURLs) }
    @objc func copy(_ sender: Any?) { FileClipboard.shared.copy(selectedURLs) }
    @objc func paste(_ sender: Any?) { FileClipboard.shared.paste(into: desktopURL) }

    @objc private func renameAction(_ sender: Any?) {
        if let i = selection.sorted().first { beginRename(i) }
    }

    @objc private func openWallpaperSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func setIconSize(_ sender: NSMenuItem) {
        guard let size = DesktopIconSize(rawValue: sender.tag), size != layout.iconSize else { return }
        layout.iconSize = size
        if layout.autoArrange { arrange(by: layout.sortKey) } else if layout.alignToGrid { snapAllToGrid() }
        needsDisplay = true
    }

    @objc private func toggleAutoArrange(_ sender: Any?) {
        layout.autoArrange.toggle()
        if layout.autoArrange { arrange(by: layout.sortKey) }
    }

    @objc private func toggleAlignToGrid(_ sender: Any?) {
        layout.alignToGrid.toggle()
        if layout.alignToGrid { snapAllToGrid() }
    }

    @objc private func toggleShowIcons(_ sender: Any?) {
        layout.showIcons.toggle()
        selection = []
        needsDisplay = true
    }

    /// Like Explorer: sorting rearranges the icons once (and keeps them sorted with auto-arrange).
    @objc private func sortBy(_ sender: NSMenuItem) {
        let key = DesktopSortKey.allCases[sender.tag]
        layout.sortKey = key
        arrange(by: key)
    }

    /// "Создать ▸ …": the new item appears where the menu was opened and goes straight into rename.
    @objc private func createNewItem(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? NewItemTemplate else { return }
        do {
            let url = try template.create(in: desktopURL)
            let spot = placement(near: menuPoint ?? firstFreeCell(occupied: centers), occupied: centers)
            setPlacement(spot, forName: url.lastPathComponent)
            layout.save()
            reload()
            if let i = index(named: url.lastPathComponent) {
                selection = [i]
                beginRename(i)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Inline rename

    private func beginRename(_ index: Int) {
        endRename()
        let item = items[index]
        let field = NSTextField(frame: labelRect(at: centers[index]).insetBy(dx: -8, dy: -2))
        field.stringValue = item.name
        field.alignment = .center
        field.font = .systemFont(ofSize: 12)
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = self
        addSubview(field)
        renameField = field
        renamingName = item.url.lastPathComponent
        renameCancelled = false
        window?.makeKey()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = FileOps.baseNameRange(of: item.name, isFolder: item.isFolder)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renameCancelled = true
        endRename()
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRename()
    }

    private func endRename() {
        guard let field = renameField, let oldName = renamingName else { return }
        renameField = nil
        renamingName = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true

        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !renameCancelled, !newName.isEmpty, newName != oldName, !newName.contains("/") else { return }
        do {
            try FileManager.default.moveItem(at: desktopURL.appendingPathComponent(oldName),
                                             to: desktopURL.appendingPathComponent(newName))
            layout.renamePosition(from: oldName, to: newName)
            reload()
            if let i = index(named: newName) { selection = [i] }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

