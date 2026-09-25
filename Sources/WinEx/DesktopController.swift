import AppKit
import Quartz
import QuickLookThumbnailing

/// Draws desktop icons in place of Finder (Finder's desktop is off in replacement mode).
/// Double-clicking a folder opens it in WinEx; icons can be moved, arranged and sorted like on Windows.
///
/// One window per monitor (with "Displays have separate Spaces" — the macOS default — a window
/// can't span monitors). All of them share one layout; each shows the icons placed on its monitor,
/// the main one also those of monitors that aren't connected.
@MainActor
final class DesktopController {
    private var desktops: [(window: DesktopWindow, view: DesktopView)] = []
    private var layout: DesktopLayout?
    private let observers = Observers()
    private var shown = false

    func show() {
        guard !shown else { return }
        shown = true
        layout = DesktopLayout(desktop: DesktopView.desktopURL, screens: DesktopView.layoutScreens())
        updateScreens()
        observers.add(NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.updateScreens() }
    }

    func resetToFinder() {
        DesktopLayout.forget()
        let fresh = DesktopLayout(desktop: DesktopView.desktopURL, screens: DesktopView.layoutScreens())
        layout = fresh
        for desktop in desktops { desktop.view.resetToFinder(fresh) }
    }

    func hide() {
        guard shown else { return }
        shown = false
        observers.removeAll()
        for desktop in desktops {
            desktop.view.stop()
            desktop.window.orderOut(nil)
        }
        desktops = []
    }

    /// A window for every monitor, main first; windows of monitors that are gone are closed.
    private func updateScreens() {
        guard let layout, let main = NSScreen.screens.first else { return }
        let screens = NSScreen.screens
        let connected = Set(screens.compactMap(\.displayUUID))
        let mainID = main.displayUUID ?? ""
        var kept: [(window: DesktopWindow, view: DesktopView)] = []
        for screen in screens {
            let id = screen.displayUUID ?? ""
            let desktop = desktops.first { $0.view.screens.first?.id == id } ?? makeDesktop(layout: layout)
            desktop.window.setFrame(screen.frame, display: true)
            let frame = screen.frame, visible = screen.visibleFrame
            desktop.view.mainScreenID = mainID
            desktop.view.connectedScreenIDs = connected
            desktop.view.screens = [DesktopView.Screen(
                id: id, frame: NSRect(origin: .zero, size: frame.size),
                iconArea: NSRect(x: visible.minX - frame.minX, y: frame.maxY - visible.maxY, width: visible.width, height: visible.height))]
            kept.append(desktop)
        }
        for desktop in desktops where !kept.contains(where: { $0.view === desktop.view }) {
            desktop.view.stop()
            desktop.window.orderOut(nil)
        }
        let isNew = kept.map { desktop in !desktops.contains { $0.view === desktop.view } }
        desktops = kept
        for (desktop, new) in zip(kept, isNew) {
            if new {
                desktop.view.start()
                desktop.window.orderFront(nil)
            } else {
                desktop.view.reloadShared()
            }
        }
    }

    private func makeDesktop(layout: DesktopLayout) -> (window: DesktopWindow, view: DesktopView) {
        let window = DesktopWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        let view = DesktopView()
        view.layout = layout
        // Icons moved to another monitor, view options changed: the other monitors follow
        view.sharedChange = { [weak self] sender in
            self?.desktops.filter { $0.view !== sender }.forEach { $0.view.reloadShared() }
        }
        // Selecting on one monitor deselects the others, like one desktop
        view.selectionStarted = { [weak self] sender in
            self?.desktops.filter { $0.view !== sender }.forEach { $0.view.clearSelection() }
        }
        window.contentView = view
        return (window, view)
    }
}

final class DesktopWindow: NSWindow {
    override var undoManager: UndoManager? { FileUndo.manager(for: self) }
    @objc func undo(_ sender: Any?) { FileUndo.manager(for: self).undo() }
    @objc func redo(_ sender: Any?) { FileUndo.manager(for: self).redo() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        FileUndo.validate(menuItem, in: self) ?? super.validateMenuItem(menuItem)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DesktopView: NSView, NSDraggingSource, NSTextFieldDelegate, NSMenuItemValidation,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate, FileMenuActions {
    /// Screen area not covered by the menu bar and Dock (view coordinates, y from the top).
    /// A monitor in view coordinates; the first is the main one.
    struct Screen: Equatable {
        var id: String
        var frame: NSRect
        /// Visible part: without the menu bar and the Dock.
        var iconArea: NSRect
    }

    var screens: [Screen] = [] { didSet { if screens != oldValue { relayout() } } }

    static let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    private var desktopURL: URL { Self.desktopURL }
    /// Shared by the desktops of all monitors (set by `DesktopController`).
    var layout: DesktopLayout!
    var mainScreenID = ""
    var connectedScreenIDs = Set<String>()
    /// Called after a change other monitors must see (icons moved here, view options).
    var sharedChange: ((DesktopView) -> Void)?
    var selectionStarted: ((DesktopView) -> Void)?

    private var isMain: Bool { screens.first?.id == mainScreenID }

    /// Whether the icon is shown on this monitor: it was placed here; or on the main monitor, it
    /// has no place yet, or its monitor isn't connected. Volumes always live on the main one.
    private func belongsHere(_ key: String, isVolume: Bool) -> Bool {
        guard !isVolume, let id = layout.place(for: key)?.screenID, connectedScreenIDs.contains(id) else { return isMain }
        return id == screens.first?.id
    }

    /// Re-reads after a change made on another monitor.
    func reloadShared() {
        reload()
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection = []
        needsDisplay = true
    }

    /// Every connected monitor, main first (Finder numbers them this way).
    static func layoutScreens() -> [DesktopLayout.Screen] {
        NSScreen.screens.map { DesktopLayout.Screen(id: $0.displayUUID ?? "", size: $0.frame.size) }
    }
    /// Desktop widgets (Notification Center windows above the icons); icons are kept out of them, like Finder does.
    private var widgetRects: [NSRect] = []
    /// Paths of volumes shown on the desktop (Finder's "Show these items on the desktop").
    private var volumePaths = Set<String>()
    /// "Show Items: On Desktop" off in System Settings.
    private var systemHidesIcons = SystemDesktop.hidesDesktopItems
    private var settingsTimer: Timer?
    private var thumbnails: [String: NSImage] = [:]
    private var requestedThumbnails = Set<String>()
    /// A plain click on empty desktop reveals the desktop like clicking the wallpaper.
    private var emptyClickCandidate = false
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
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        reload()
        watcher = DirectoryWatcher(url: desktopURL) { [weak self] in self?.reload() }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.add(name, center: NSWorkspace.shared.notificationCenter) { [weak self] in self?.reload() }
        }
        // System Settings has no change notification for these; poll cheaply
        settingsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let hides = SystemDesktop.hidesDesktopItems
                if hides != self.systemHidesIcons {
                    self.systemHidesIcons = hides
                    self.selection = []
                    self.needsDisplay = true
                }
            }
        }
        observers.add(FileClipboard.didChange) { [weak self] in self?.needsDisplay = true }
        observers.add(.fileTagsChanged) { [weak self] in self?.reload() }
    }

    private let observers = Observers()

    func stop() {
        endRename()
        watcher = nil
        observers.removeAll()
        settingsTimer?.invalidate()
        settingsTimer = nil
    }

    private var iconsVisible: Bool { layout.showIcons && !systemHidesIcons }

    // MARK: - Items and layout

    private func reload() {
        let selectedNames = Set(selection.map { name(of: $0) })
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: desktopURL, includingPropertiesForKeys: FileItem.keys, options: [.skipsHiddenFiles])) ?? []
        let volumes = SystemDesktop.desktopVolumes()
        volumePaths = Set(volumes.map(\.path))
        let all = volumes.map(FileItem.init) + urls.map(FileItem.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Forget places of files that are gone — judged by the whole desktop, not this monitor's part
        let volumeCount = volumes.count
        func key(_ n: Int) -> String { n < volumeCount ? all[n].url.path : all[n].url.lastPathComponent }
        layout.prune(keeping: Set(all.indices.map(key)))
        items = all.indices.filter { belongsHere(key($0), isVolume: $0 < volumeCount) }.map { all[$0] }
        // Drop previews of files that are gone or changed
        let live = Set(items.map(thumbnailKey))
        thumbnails = thumbnails.filter { live.contains($0.key) }
        requestedThumbnails.formIntersection(live)
        selection = Set(items.indices.filter { selectedNames.contains(name(of: $0)) })
        relayout()
    }

    /// Layout key of an item: the file name for desktop files, the full path for volumes.
    private func name(of index: Int) -> String {
        isVolume(index) ? items[index].url.path : items[index].url.lastPathComponent
    }

    private func index(named name: String) -> Int? {
        items.indices.first { self.name(of: $0) == name }
    }

    private func isVolume(_ index: Int) -> Bool {
        volumePaths.contains(items[index].url.path)
    }

    /// Places every icon: stored positions, free grid cells for new files, or a sorted grid with auto-arrange.
    private func relayout() {
        guard !screens.isEmpty else { return }
        widgetRects = Self.widgetFrames(in: window)
        centers = Array(repeating: .zero, count: items.count)
        if layout.autoArrange {
            arrange(by: layout.sortKey)
            return
        }
        var placed: [CGPoint] = []
        var unplaced: [Int] = []
        var displaced: [Int] = []
        for i in items.indices {
            guard let place = layout.place(for: name(of: i)) else { unplaced.append(i); continue }
            // On a monitor that isn't connected: shown on the main one for now (see below)
            let screen = screens.first { $0.id == place.screenID } ?? screens[0]
            let away = place.screenID != nil && screen.id != place.screenID
            centers[i] = clamp(CGPoint(x: screen.frame.minX + place.point.x * screen.frame.width,
                                       y: screen.frame.minY + place.point.y * screen.frame.height))
            if away || isUnderWidget(centers[i]) { displaced.append(i) } else { placed.append(centers[i]) }
        }
        // Icons under a widget or from a disconnected monitor go to the nearest free cell; their
        // stored position is kept, so they come back when the widget goes away / the monitor returns
        for i in displaced {
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

    /// Settings ▸ reset: positions and view options as Finder has them.
    func resetToFinder(_ fresh: DesktopLayout) {
        endRename()
        layout = fresh
        thumbnails = [:]
        requestedThumbnails = []
        selection = []
        reload()
    }

    private func storePosition(of index: Int) {
        layout.setPlace(place(of: centers[index]), for: name(of: index))
    }

    /// A point in view coordinates as a stored place: fractions of the monitor it's on.
    private func place(of point: CGPoint) -> DesktopLayout.Place {
        let screen = self.screen(at: point)
        let main = mainScreenID
        return DesktopLayout.Place(point: CGPoint(x: (point.x - screen.frame.minX) / max(screen.frame.width, 1),
                                                  y: (point.y - screen.frame.minY) / max(screen.frame.height, 1)),
                                   screenID: screen.id == main ? nil : screen.id)
    }

    /// The monitor showing `point`, or the nearest one.
    private func screen(at point: CGPoint) -> Screen {
        func distance(_ rect: NSRect) -> CGFloat {
            hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
        }
        return screens.min { distance($0.frame) < distance($1.frame) } ?? Screen(id: "", frame: bounds, iconArea: bounds)
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
        guard iconsVisible else { return nil }
        // Topmost (last drawn) first
        return items.indices.reversed().first { hitRect($0).contains(point) }
    }

    /// Keeps an icon (and its label) inside the visible area of its monitor.
    private func clamp(_ point: CGPoint) -> CGPoint {
        let iconArea = screen(at: point).iconArea
        let minX = iconArea.minX + cellSize.width / 2, maxX = iconArea.maxX - cellSize.width / 2
        let minY = iconArea.minY + iconSide / 2 + 4, maxY = iconArea.maxY - iconSide / 2 - 38
        return CGPoint(x: min(max(point.x, minX), max(minX, maxX)), y: min(max(point.y, minY), max(minY, maxY)))
    }

    /// Grid cells of every monitor (main first), each filled in columns from the top-right corner,
    /// where macOS keeps desktop icons.
    private func gridCells() -> [CGPoint] {
        screens.flatMap { gridCells(in: $0.iconArea) }
    }

    private func gridCells(in iconArea: NSRect) -> [CGPoint] {
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
        guard let window, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let screenTop = NSScreen.screens.first.map { $0.frame.maxY } ?? 0
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer > desktopLevel, layer < 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.notificationcenterui",
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            // Window-list y is measured from the top of the primary screen
            return NSRect(x: rect.minX - window.frame.minX, y: rect.minY - (screenTop - window.frame.maxY),
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
        layout.setPlace(place(of: point), for: name)
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

    // MARK: - Drawing
    //
    // The view itself has no bitmap: a full-screen backing store would cost tens of megabytes.
    // Its layer is an almost-transparent color (enough for the window server to send us clicks on
    // empty desktop — context menu, rubber band), and each icon is drawn by a small tile view.

    override var wantsUpdateLayer: Bool { true }

    /// Any `needsDisplay = true` lands here: match the tiles to the items and redraw them.
    override func updateLayer() {
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.005).cgColor
        let count = iconsVisible ? items.count : 0
        while tiles.count > count { tiles.removeLast().removeFromSuperview() }
        while tiles.count < count {
            let tile = DesktopIconTile(owner: self, index: tiles.count)
            // Later items on top (as `index(at:)` assumes), all under the rename field
            if let other = subviews.first(where: { !($0 is DesktopIconTile) }) {
                addSubview(tile, positioned: .below, relativeTo: other)
            } else {
                addSubview(tile)
            }
            tiles.append(tile)
        }
        for (i, tile) in tiles.enumerated() {
            tile.frame = hitRect(i).insetBy(dx: -6, dy: -6)
            tile.needsDisplay = true
        }
        rubberBandView.frame = rubberBand ?? .zero
        rubberBandView.isHidden = rubberBand == nil
        if rubberBand != nil { addSubview(rubberBandView) } // on top of the icons
    }

    private var tiles: [DesktopIconTile] = []
    private let rubberBandView = DesktopRubberBandView()

    fileprivate func drawIcon(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let item = items[i]
        let attributes = labelAttributes()
        let iconRect = iconRect(at: centers[i])
        let labelRect = labelRect(at: centers[i])
        let isRenaming = renamingName == name(of: i)
        let lines = DesktopLabel.lines(labelText(for: item, attributes: attributes), width: labelRect.width)
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 12)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineRects = lines.enumerated().map { n, line in
            let width = min(ceil(line.size().width), labelRect.width)
            return NSRect(x: labelRect.midX - width / 2, y: labelRect.minY + CGFloat(n) * lineHeight, width: width, height: lineHeight)
        }

        if selection.contains(i) || dropTarget == i {
            NSColor.white.withAlphaComponent(dropTarget == i ? 0.35 : 0.2).setFill()
            NSBezierPath(roundedRect: iconRect.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6).fill()
        }
        if selection.contains(i) && !isRenaming {
            // One rounded highlight per line, like Finder
            NSColor.selectedContentBackgroundColor.setFill()
            for rect in lineRects {
                NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -1), xRadius: 4, yRadius: 4).fill()
            }
        }
        let alpha = FileClipboard.shared.isCut(item.url) ? FileListViewController.cutAlpha : 1
        let image = image(for: i)
        let imageRect = Self.aspectFit(image.size, in: iconRect)
        NSGraphicsContext.saveGraphicsState()
        if thumbnails[thumbnailKey(item)] === image {
            // Previews get rounded corners, like Finder's
            let radius = max(3, min(imageRect.width, imageRect.height) * 0.1)
            NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius).addClip()
        }
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        if !isRenaming {
            for (line, rect) in zip(lines, lineRects) {
                line.draw(in: rect.insetBy(dx: -2, dy: 0))
            }
        }
    }

    /// Largest rect with the image's proportions inside `rect` (previews aren't square).
    static func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// Name with Finder's colored tag dots in front of it.
    private func labelText(for item: FileItem, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: FileTags.dots(for: item.tags, attributes: attributes))
        text.append(NSAttributedString(string: item.name, attributes: attributes))
        return text
    }

    private func thumbnailKey(_ item: FileItem) -> String {
        "\(Int(iconSide))|\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.url.path)"
    }

    /// Previews for pictures, PDFs, documents… like Finder's "Show icon preview"; icons for folders and apps.
    private func image(for index: Int) -> NSImage {
        let item = items[index]
        guard !item.isFolder, !isVolume(index), item.url.pathExtension != "app" else { return item.icon }
        let side = iconSide
        let key = thumbnailKey(item)
        if let cached = thumbnails[key] { return cached }
        if !requestedThumbnails.contains(key) {
            requestedThumbnails.insert(key)
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: side, height: side),
                                                       scale: window?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let image = representation?.nsImage else { return }
                DispatchQueue.main.async {
                    self?.thumbnails[key] = image
                    self?.needsDisplay = true
                }
            }
        }
        return item.icon
    }

    // MARK: - Mouse

    private let slowClick = SlowClickRename()
    private var slowClickIndex: Int?

    override func mouseDown(with event: NSEvent) {
        slowClick.cancel()
        slowClickIndex = nil
        endRename()
        window?.makeKey()
        window?.makeFirstResponder(self)
        selectionStarted?(self)
        let point = convert(event.locationInWindow, from: nil)
        let toggles = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        mouseDownPoint = point
        dragStarted = false
        collapseOnMouseUp = nil
        mouseDownIndex = index(at: point)

        if let i = mouseDownIndex {
            // Slow click on the label of the only selected icon → rename (files only, not disks)
            if SlowClickRename.isPlainClick(event), selection == [i], !isVolume(i), labelRect(at: centers[i]).contains(point) {
                slowClickIndex = i
            }
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
            emptyClickCandidate = !toggles && event.clickCount == 1
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if rubberBand != nil {
            let rect = NSRect(x: min(point.x, mouseDownPoint.x), y: min(point.y, mouseDownPoint.y),
                              width: abs(point.x - mouseDownPoint.x), height: abs(point.y - mouseDownPoint.y))
            rubberBand = rect
            selection = rubberBandBase.union(items.indices.filter { iconsVisible && hitRect($0).intersects(rect) })
            if rect.width > 3 || rect.height > 3 { emptyClickCandidate = false }
            needsDisplay = true
            return
        }
        guard mouseDownIndex != nil, !dragStarted,
              hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        dragStarted = true
        collapseOnMouseUp = nil
        slowClickIndex = nil
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
        if let i = slowClickIndex, !dragStarted {
            let name = name(of: i)
            slowClick.schedule { [weak self] in
                guard let self, let index = self.index(named: name), self.selection == [index] else { return }
                self.beginRename(index)
            }
        }
        slowClickIndex = nil
        // Clicking the wallpaper moves windows aside (and back), as System Settings asks
        if emptyClickCandidate && rubberBand != nil && SystemDesktop.clickRevealsDesktop {
            SystemDesktop.toggleShowDesktop()
        }
        emptyClickCandidate = false
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
        // Dropped on the Trash in the Dock: files go to the Trash, volumes are ejected (like Finder)
        if operation == .delete { removeItems(draggedNames.compactMap(index(named:))) }
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
        // Icons dragged over from another monitor: already on the desktop, only their place changes
        if !FileDrop.perform(sender, into: desktopURL) { reload() }
        sharedChange?(self)
        return true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        slowClick.cancel()
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (36, []), (76, []): if Settings.windowsKeys { openSelection() } else { renameSelected(nil) }
        case (51, [.command]): trashSelection()
        case (0, [.command]): selection = Set(items.indices); needsDisplay = true
        case (120, []) where Settings.windowsKeys: renameSelected(nil)                  // F2
        case (125, [.command]): openSelection()                                       // ⌘↓ (Finder)
        case (53, []): selection = []; needsDisplay = true                           // Esc
        case (49, []): if !selection.isEmpty { QuickLook.toggle(for: self) }                    // Space
        case (123, []), (124, []), (125, []), (126, []): moveSelection(keyCode: event.keyCode, extend: false)
        case (123, [.shift]), (124, [.shift]), (125, [.shift]), (126, [.shift]): moveSelection(keyCode: event.keyCode, extend: true)
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

        if let i = index(at: point), isVolume(i) {
            if !selection.contains(i) { selection = [i]; needsDisplay = true }
            add("Открыть", #selector(openSelected(_:)))
            if let openWith = OpenWithMenu.item(for: selectedURLs) { menu.addItem(openWith) }
            menu.addItem(.separator())
            add("Копировать путь", #selector(copyPath(_:)))
            menu.addItem(.separator())
            add("Извлечь «\(items[i].name)»", #selector(moveToTrash(_:)))
            menu.addItem(.separator())
            add("Свойства", #selector(showProperties(_:)))
            return menu
        }

        if let i = index(at: point) {
            if !selection.contains(i) { selection = [i]; needsDisplay = true }
            FileContextMenu.addItems(to: menu, for: selectedFileURLs, target: self, folderTabs: false,
                                     customizableFolder: selection.count == 1 && items[i].isFolder)
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
        guard !selection.isEmpty else { return }
        removeItems(Array(selection))
        selection = []
    }

    /// Files go to the Trash; volumes are ejected.
    private func removeItems(_ indexes: [Int]) {
        let volumes = indexes.filter(isVolume).map { items[$0].url }
        let files = indexes.filter { !isVolume($0) }.map { items[$0].url }
        if !files.isEmpty { FileOps.trash(files) }
        volumes.forEach(SystemDesktop.eject)
    }

    /// Selected desktop files (volumes can't be cut or renamed).
    private var selectedFileURLs: [URL] { selection.sorted().filter { !isVolume($0) }.map { items[$0].url } }

    @objc func openSelected(_ sender: Any?) { openSelection() }

    /// ⇧⌘N on the desktop: a new folder in the first free spot, straight into renaming.
    @objc func newFolder(_ sender: Any?) {
        let url = FileOps.newFolderURL(in: desktopURL)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        FileUndo.recordCreate(url)
        setPlacement(firstFreeCell(occupied: centers), forName: url.lastPathComponent)
        layout.save()
        reload()
        if let i = index(named: url.lastPathComponent) {
            selection = [i]
            beginRename(i)
        }
    }

    /// ⌘I / ⌥↩ reach here through the main menu when the desktop is focused.
    @objc func showProperties(_ sender: Any?) {
        PropertiesWindowController.show(for: selectedURLs.isEmpty ? [desktopURL] : selectedURLs)
    }

    @objc func share(_ sender: Any?) {
        guard let i = selection.sorted().first else { return }
        NSSharingServicePicker(items: selectedFileURLs).show(relativeTo: iconRect(at: centers[i]), of: self, preferredEdge: .maxY)
    }

    @objc func customizeFolder(_ sender: Any?) {
        guard let i = selection.first, items.indices.contains(i) else { return }
        FolderCustomizationController.show(for: items[i].url, relativeTo: iconRect(at: centers[i]), of: self)
    }

    @objc func toggleTag(_ sender: NSMenuItem) { FileContextMenu.toggleTag(sender) }
    @objc func quickLook(_ sender: Any?) { QuickLook.toggle(for: self) }

    /// Arrow keys pick the nearest icon in that direction (icons are freely placed, so by geometry).
    /// With ⇧ the next icon is added to the selection (the keyboard focus moves on from it).
    private func moveSelection(keyCode: UInt16, extend: Bool) {
        guard iconsVisible, !items.isEmpty else { return }
        guard let current = keyboardLead.flatMap({ selection.contains($0) ? $0 : nil }) ?? selection.sorted().first else {
            selection = [0]
            keyboardLead = 0
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
        if extend { selection.insert(next) } else { selection = [next] }
        keyboardLead = next
        needsDisplay = true
    }

    /// Icon the arrow keys move from (the last one reached with the keyboard).
    private var keyboardLead: Int?

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
        // The same rect and picture the desktop draws (preview, not the generic icon, in its own proportions)
        let drawn = Self.aspectFit(image(for: i).size, in: iconRect(at: centers[i]))
        return window.convertToScreen(convert(drawn, to: nil))
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item?.previewItemURL, let i = items.firstIndex(where: { $0.url.path == url.path }) else { return nil }
        let image = image(for: i)
        contentRect?.pointee = NSRect(origin: .zero, size: image.size)
        return image
    }
    @objc func copyPath(_ sender: Any?) { FileOps.copyPaths(selectedURLs) }
    @objc func moveToTrash(_ sender: Any?) { trashSelection() }
    @objc private func refreshAction(_ sender: Any?) { reload() }
    @objc private func openDesktopAction(_ sender: Any?) { AppDelegate.shared.openWindow(at: desktopURL) }

    // ⌘X / ⌘C / ⌘V arrive here through the main menu when the desktop is focused
    @objc func cut(_ sender: Any?) { FileClipboard.shared.cut(selectedFileURLs) }
    @objc func copy(_ sender: Any?) { FileClipboard.shared.copy(selectedURLs) }
    @objc func paste(_ sender: Any?) { FileClipboard.shared.paste(into: desktopURL) }

    @objc func renameSelected(_ sender: Any?) {
        if let i = selection.sorted().first(where: { !isVolume($0) }) { beginRename(i) }
    }

    @objc private func openWallpaperSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func setIconSize(_ sender: NSMenuItem) {
        guard let size = DesktopIconSize(rawValue: sender.tag), size != layout.iconSize else { return }
        layout.iconSize = size
        thumbnails = [:]
        requestedThumbnails = []
        if layout.autoArrange { arrange(by: layout.sortKey) } else if layout.alignToGrid { snapAllToGrid() }
        needsDisplay = true
        sharedChange?(self)
    }

    @objc private func toggleAutoArrange(_ sender: Any?) {
        layout.autoArrange.toggle()
        if layout.autoArrange { arrange(by: layout.sortKey) }
        sharedChange?(self)
    }

    @objc private func toggleAlignToGrid(_ sender: Any?) {
        layout.alignToGrid.toggle()
        if layout.alignToGrid { snapAllToGrid() }
        sharedChange?(self)
    }

    @objc private func toggleShowIcons(_ sender: Any?) {
        layout.showIcons.toggle()
        selection = []
        needsDisplay = true
        sharedChange?(self)
    }

    /// Like Explorer: sorting rearranges the icons once (and keeps them sorted with auto-arrange).
    @objc private func sortBy(_ sender: NSMenuItem) {
        let key = DesktopSortKey.allCases[sender.tag]
        layout.sortKey = key
        arrange(by: key)
        sharedChange?(self)
    }

    /// "Создать ▸ …": the new item appears where the menu was opened and goes straight into rename.
    @objc private func createNewItem(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? NewItemTemplate else { return }
        do {
            let url = try template.create(in: desktopURL)
            FileUndo.recordCreate(url)
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
            FileUndo.recordRename(from: desktopURL.appendingPathComponent(oldName), to: desktopURL.appendingPathComponent(newName))
            layout.renamePosition(from: oldName, to: newName)
            reload()
            if let i = index(named: newName) { selection = [i] }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Draws one desktop icon with its label; the desktop view does the drawing, in its coordinates.
private final class DesktopIconTile: NSView {
    private unowned let owner: DesktopView
    private let index: Int

    init(owner: DesktopView, index: Int) {
        self.owner = owner
        self.index = index
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shift = NSAffineTransform()
        shift.translateX(by: -frame.minX, yBy: -frame.minY)
        shift.concat()
        owner.drawIcon(index)
    }
}

/// The desktop's selection rectangle.
private final class DesktopRubberBandView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).setFill()
        bounds.fill(using: .sourceOver)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.8).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
