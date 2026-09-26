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

    /// A picture of the whole desktop (every monitor as arranged, wallpaper, icons, zones) for a
    /// snapshot, `width` points wide.
    func previewImage(width: CGFloat = 960) -> NSImage? {
        guard shown, !desktops.isEmpty else { return nil }
        let frames = desktops.compactMap { $0.window.screen?.frame ?? $0.window.frame }
        let union = frames.reduce(NSRect.null) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return nil }
        let scale = width / union.width
        let size = NSSize(width: width, height: (union.height * scale).rounded())
        return NSImage(size: size, flipped: false) { _ in
            NSColor(white: 0.1, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            for desktop in self.desktops {
                guard let screen = desktop.window.screen else { continue }
                let frame = screen.frame
                let target = NSRect(x: (frame.minX - union.minX) * scale, y: (frame.minY - union.minY) * scale,
                                    width: frame.width * scale, height: frame.height * scale)
                if let url = NSWorkspace.shared.desktopImageURL(for: screen), let wallpaper = NSImage(contentsOf: url) {
                    // Aspect fill, like the wallpaper itself
                    let ratio = max(target.width / max(wallpaper.size.width, 1), target.height / max(wallpaper.size.height, 1))
                    let drawn = NSSize(width: wallpaper.size.width * ratio, height: wallpaper.size.height * ratio)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: target).addClip()
                    wallpaper.draw(in: NSRect(x: target.midX - drawn.width / 2, y: target.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
                    NSGraphicsContext.restoreGraphicsState()
                }
                // The icons and zones on a transparent bitmap (the view's own cache is opaque white)
                let view = desktop.view
                let pixels = NSSize(width: (target.width * 2).rounded(), height: (target.height * 2).rounded())
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                    rep.size = view.bounds.size
                    view.cacheDisplay(in: view.bounds, to: rep)
                    rep.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            return true
        }
    }

    /// The stored arrangement changed underneath (a snapshot restored): every monitor re-reads it.
    func reloadLayout() {
        guard shown else { return }
        let fresh = DesktopLayout(desktop: DesktopView.desktopURL, screens: DesktopView.layoutScreens())
        layout = fresh
        for desktop in desktops { desktop.view.resetToFinder(fresh) }
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
        // Quick-hide is for the whole desktop, every monitor
        view.quickHideChange = { [weak self] sender, hidden in
            self?.desktops.filter { $0.view !== sender }.forEach { $0.view.setQuickHidden(hidden, fromOtherMonitor: true) }
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
    /// Widgets and fences: other icons stay out of these.
    private var blockedRects: [NSRect] = []

    // Fences
    private var fenceViews: [String: FenceView] = [:]
    private let guidesView = FenceGuidesView()
    private let fenceHint = FenceHintButton()
    /// An empty area just selected with the mouse: a zone can be made there (the hint offers it).
    private var emptyArea: NSRect?
    private let areaOutline = FenceAreaOutline()
    /// First visible row of each fence (scrolled with the wheel).
    /// How far each fence's icons are scrolled, in points (like a scroll view).
    private var fenceScroll: [String: CGFloat] = [:]
    /// The part of the fence a member icon may show in (its icon is cut off beyond it).
    private var fenceClip: [Int: NSRect] = [:]
    /// Icons of collapsed fences and below a fence's visible rows.
    private var hiddenIcons = Set<Int>()
    /// Icon index → the fence it's in (on this monitor).
    private var fenceOf: [Int: String] = [:]
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
        observers.add(FenceStyle.didChange) { [weak self] in
            self?.fenceViews.values.forEach { $0.styleChanged() }
            self?.relayout()  // switched on / off
        }
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
        layoutFences()
        // A rolled-up fence keeps its whole place: rolling it up or down moves nothing else
        blockedRects = widgetRects + myFences.map { visibleFrame(of: $0, whole: true).insetBy(dx: -4, dy: -4) }
        if layout.autoArrange {
            arrange(by: layout.sortKey)
            return
        }
        var placed: [CGPoint] = []
        var unplaced: [Int] = []
        var displaced: [Int] = []
        var overlapped: Set<Int> = []
        // Icons stored with their monitor claim their spots first; then those stored as "on the
        // main monitor" (older positions, Finder's) — after a monitor change the main one may be
        // another monitor, and such an icon must not land on top of one that really lives there
        let places = items.indices.map { layout.place(for: name(of: $0)) }
        let order = items.indices.filter { fenceOf[$0] == nil }
            .sorted { (places[$0]?.screenID == nil ? 1 : 0) < (places[$1]?.screenID == nil ? 1 : 0) }
        for i in order {
            guard let place = places[i] else { unplaced.append(i); continue }
            // On a monitor that isn't connected: shown on the main one for now (see below)
            let screen = screens.first { $0.id == place.screenID } ?? screens[0]
            let away = place.screenID != nil && screen.id != place.screenID
            centers[i] = clamp(CGPoint(x: screen.frame.minX + place.point.x * screen.frame.width,
                                       y: screen.frame.minY + place.point.y * screen.frame.height))
            if away || isUnderWidget(centers[i]) {
                displaced.append(i)
            } else if overlapsAnother(centers[i], placed) {
                displaced.append(i)
                overlapped.insert(i)
            } else {
                placed.append(centers[i])
            }
        }
        // Icons under a widget, from a disconnected monitor or on top of another go to the nearest free cell; their
        // stored position is kept, so they come back when the widget goes away / the monitor returns
        for i in displaced {
            centers[i] = nearestFreeCell(to: centers[i], occupied: placed)
            placed.append(centers[i])
            // On top of another icon: where it went is its place from now on — otherwise it would
            // jump into the first spot that frees up (a file deleted nearby)
            if overlapped.contains(i) { storePosition(of: i) }
        }
        for i in unplaced {
            centers[i] = firstFreeCell(occupied: placed)
            placed.append(centers[i])
            storePosition(of: i)
        }
        if !unplaced.isEmpty || !overlapped.isEmpty { layout.save() }
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
        // Always with its monitor, the main one too: "the main one" changes with the monitors
        return DesktopLayout.Place(point: CGPoint(x: (point.x - screen.frame.minX) / max(screen.frame.width, 1),
                                                  y: (point.y - screen.frame.minY) / max(screen.frame.height, 1)),
                                   screenID: screen.id.isEmpty ? nil : screen.id)
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

    private func labelRect(at center: CGPoint, cellWidth: CGFloat? = nil) -> NSRect {
        // Below the selection square (6 pt around the icon) with a clear gap, like Finder
        let width = cellWidth ?? cellSize.width
        return NSRect(x: center.x - width / 2 + 2, y: center.y + iconSide / 2 + 9, width: width - 4, height: 32)
    }

    /// An icon's label: narrower in a fence (its cells are compact).
    private func labelRect(_ index: Int) -> NSRect {
        labelRect(at: centers[index], cellWidth: fenceOf[index] != nil ? fenceCell.width : nil)
    }


    private func hitRect(_ index: Int) -> NSRect {
        iconRect(at: centers[index]).insetBy(dx: -4, dy: -4).union(labelRect(index))
    }

    private func index(at point: NSPoint) -> Int? {
        guard iconsVisible else { return nil }
        // Topmost (last drawn) first
        guard !quickHidden else { return nil }
        return items.indices.reversed().first {
            !hiddenIcons.contains($0) && hitRect($0).contains(point) && fenceClip[$0].map { $0.contains(point) } != false
        }
    }

    /// Keeps an icon (and its label) inside the visible area of its monitor.
    private func clamp(_ point: CGPoint) -> CGPoint {
        let iconArea = screen(at: point).iconArea
        let minX = iconArea.minX + cellSize.width / 2, maxX = iconArea.maxX - cellSize.width / 2
        let minY = iconArea.minY + iconSide / 2 + 8, maxY = iconArea.maxY - iconSide / 2 - 46
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
                                     y: iconArea.minY + 12 + iconSide / 2 + 8 + cellSize.height * CGFloat(row)))
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
        return blockedRects.contains { $0.intersects(cell) }
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

    /// Too close to an icon already placed: the two would be drawn over each other.
    #if DEBUG
    /// Scenario check: where an icon is drawn.
    func debugCenter(of name: String) -> CGPoint? {
        items.indices.first { self.name(of: $0) == name }.map { centers[$0] }
    }
    #endif

    private func overlapsAnother(_ point: CGPoint, _ placed: [CGPoint]) -> Bool {
        placed.contains { abs($0.x - point.x) < cellSize.width * 0.75 && abs($0.y - point.y) < cellSize.height * 0.75 }
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
        let order = items.indices.filter { fenceOf[$0] == nil }.sorted { a, b in
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
        let cells = gridCells().filter { !isUnderWidget($0) }
        for (n, i) in order.enumerated() {
            centers[i] = cells.indices.contains(n) ? cells[n] : (cells.last ?? .zero)
        }
        storeAllPositions()
    }

    /// Moves every icon to the nearest free grid cell ("Align icons to grid").
    private func snapAllToGrid() {
        var occupied: [CGPoint] = []
        let order = items.indices.filter { fenceOf[$0] == nil }.sorted { centers[$0].x != centers[$1].x ? centers[$0].x > centers[$1].x : centers[$0].y < centers[$1].y }
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
        var occupied = items.indices.filter { !moving.contains(name(of: $0)) && fenceOf[$0] == nil }.map { centers[$0] }
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
        return [.font: NSFont.systemFont(ofSize: layout.iconSize == .small ? 11 : 12, weight: .bold),  // Finder's desktop weight
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
        syncFenceViews()
        let count = iconsVisible ? items.count : 0
        while tiles.count > count { tiles.removeLast().removeFromSuperview() }
        while tiles.count < count {
            let tile = DesktopIconTile(owner: self, index: tiles.count)
            if quickHidden { tile.alphaValue = 0 }  // quick-hidden: new icons stay hidden too
            // Later items on top (as `index(at:)` assumes), above the fences, under the rename field
            if let other = subviews.first(where: { !($0 is DesktopIconTile) && !($0 is FenceView) }) {
                addSubview(tile, positioned: .below, relativeTo: other)
            } else {
                addSubview(tile)
            }
            tiles.append(tile)
        }
        for (i, tile) in tiles.enumerated() {
            tile.frame = hitRect(i).insetBy(dx: -6, dy: -6)
            tile.isHidden = hiddenIcons.contains(i)
            tile.clip(to: fenceClip[i])
            tile.needsDisplay = true
        }
        if guidesView.superview == nil { addSubview(guidesView) }
        guidesView.frame = bounds
        addSubview(guidesView, positioned: .above, relativeTo: nil)
        updateFenceHint()
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
        let labelRect = labelRect(i)
        let isRenaming = renamingName == name(of: i)
        let lines = DesktopLabel.lines(labelText(for: item, attributes: attributes), width: labelRect.width)
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 12)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineRects = lines.enumerated().map { n, line in
            let width = min(ceil(line.size().width), labelRect.width)
            return NSRect(x: labelRect.midX - width / 2, y: labelRect.minY + CGFloat(n) * lineHeight, width: width, height: lineHeight)
        }

        if selection.contains(i) || dropTarget == i {
            // Finder's desktop: a dark translucent square with a light border
            let square = NSBezierPath(roundedRect: iconRect.insetBy(dx: -5, dy: -5), xRadius: 10, yRadius: 10)
            NSColor.black.withAlphaComponent(dropTarget == i ? 0.45 : 0.3).setFill()
            square.fill()
            NSColor.white.withAlphaComponent(0.4).setStroke()
            square.lineWidth = 2
            square.stroke()
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
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
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
            // Finder's look: documents as rounded pages, pictures as rounded cards
            request.iconMode = true
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
        emptyArea = nil
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
            if SlowClickRename.isPlainClick(event), selection == [i], !isVolume(i), labelRect(i).contains(point) {
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
            // Double-click on the wallpaper: every icon and fence hides (again: they come back)
            if event.clickCount == 2, !toggles, FenceStyle.quickHide, fence(at: point) == nil {
                setQuickHidden(!quickHidden)
                return
            }
            rubberBandBase = toggles ? selection : []
            selection = rubberBandBase
            rubberBand = NSRect(origin: point, size: .zero)
            // Inside a fence it's the fence's space, not the wallpaper: no "show desktop"
            emptyClickCandidate = !toggles && event.clickCount == 1 && fence(at: point) == nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if rubberBand != nil {
            let rect = NSRect(x: min(point.x, mouseDownPoint.x), y: min(point.y, mouseDownPoint.y),
                              width: abs(point.x - mouseDownPoint.x), height: abs(point.y - mouseDownPoint.y))
            rubberBand = rect
            selection = rubberBandBase.union(items.indices.filter { iconsVisible && !hiddenIcons.contains($0) && hitRect($0).intersects(rect) })
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
            // The picture the desktop shows (a preview, not the file type's icon), same proportions
            let image = image(for: i)
            item.setDraggingFrame(Self.aspectFit(image.size, in: iconRect(at: centers[i])), contents: image)
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
        // Right away, like Finder; a second click (double-click) then only hides the icons
        if emptyClickCandidate && rubberBand != nil && SystemDesktop.clickRevealsDesktop {
            SystemDesktop.toggleShowDesktop()
        }
        // Nothing caught in a sizeable frame on the bare wallpaper: offer a zone right there
        if let band = rubberBand, selection.isEmpty, FenceStyle.enabled, iconsVisible,
           band.width >= fenceCell.width, band.height >= DesktopFence.titleHeight + fenceCell.height * 0.6,
           let area = screens.first?.iconArea, area.contains(band),
           !myFences.contains(where: { visibleFrame(of: $0, whole: true).intersects(band) }) {
            emptyArea = band
        }
        emptyClickCandidate = false
        rubberBand = nil
        mouseDownIndex = nil
        collapseOnMouseUp = nil
        needsDisplay = true
    }

    // MARK: - Dragging source

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dropped on the Trash in the Dock: files go to the Trash, volumes are ejected (like Finder)
        if operation == .delete { removeItems(draggedNames.compactMap(index(named:))) }
        draggedNames = []
        dragStarted = false
        needsDisplay = true
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
        highlightFence(target == nil ? fence(at: point).flatMap { $0.isPortal ? nil : $0.id } : nil)
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
        highlightFence(nil)
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let target = dropTarget
        dropTarget = nil
        highlightFence(nil)
        needsDisplay = true

        if let target, FileDrop.perform(sender, into: items[target].url) { return true }
        let fenceHere = fence(at: point).flatMap { $0.isPortal ? nil : $0 }
        if isOwnDrag(sender) {
            if let fenceHere {
                addToFence(fenceHere.id, names: draggedNames, at: point)
            } else {
                // Out of their fences, onto the desktop where they were dropped
                removeFromFences(draggedNames)
                moveIcons(named: draggedNames, by: CGSize(width: point.x - dragOrigin.x, height: point.y - dragOrigin.y))
            }
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
        if let fenceHere {
            addToFence(fenceHere.id, names: urls.map(\.lastPathComponent), at: point, relayoutNow: false)
        } else {
            removeFromFences(urls.map(\.lastPathComponent))
        }
        // Icons dragged over from another monitor: already on the desktop, only their place changes
        if !FileDrop.perform(sender, into: desktopURL) { reload() }
        sharedChange?(self)
        return true
    }

    // MARK: - Scrolling fences

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let fence = fence(at: point), !fence.collapsed else { return super.scrollWheel(with: event) }
        // Smoothly, point by point, like the portals' scroll views (a mouse wheel: a line at a time)
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        let offset = min(max((fenceScroll[fence.id] ?? 0) - delta, 0), maxScroll(fence))
        guard offset != fenceScroll[fence.id] ?? 0 else { return }
        fenceScroll[fence.id] = offset
        // Only the fences' icons move: no need to place everything again
        layoutFences()
        syncFenceViews()
        needsDisplay = true
    }

    /// How far a fence's icons can scroll: all their rows minus what the fence shows.
    private func maxScroll(_ fence: DesktopFence) -> CGFloat {
        let grid = fenceGrid(fence)
        let count = fence.members.filter { index(named: $0) != nil }.count
        let rows = CGFloat(Int(ceil(Double(count) / Double(grid.columns))))
        return max(0, fenceTopExtra + rows * fenceCell.height + 4 - grid.content.height)
    }


    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        slowClick.cancel()
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (36, []), (76, []): if Settings.windowsKeys { openSelection() } else { renameSelected(nil) }
        case (51, [.command]): trashSelection()
        case (0, [.command]): selection = Set(items.indices); needsDisplay = true
        case (5, [.command]):
            if let area = emptyArea, selection.isEmpty { makeFence(in: area) }
            else if FenceStyle.enabled && selection.count >= 1 { fenceFromSelection(nil) }                // ⌘G: into a fence
        case (120, []) where Settings.windowsKeys: renameSelected(nil)                  // F2
        case (117, []) where Settings.windowsKeys: trashSelection()                     // Delete
        case (117, [.shift]) where Settings.windowsKeys:                                 // ⇧Delete
            Places.deleteForever(selectedFileURLs, emptying: false)
        case (96, []) where Settings.windowsKeys: reload()                              // F5
        case (125, [.command]): openSelection()                                       // ⌘↓ (Finder)
        case (53, []): selection = []; emptyArea = nil; needsDisplay = true          // Esc
        case (49, []): if !selection.isEmpty { QuickLook.toggle(for: self) }                    // Space
        case (123, []), (124, []), (125, []), (126, []): moveSelection(keyCode: event.keyCode, extend: false)
        case (123, [.shift]), (124, [.shift]), (125, [.shift]), (126, [.shift]): moveSelection(keyCode: event.keyCode, extend: true)
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        emptyArea = nil
        needsLayout = true
        let menu = buildMenu(for: event)
        menu.map(MenuStyle.decorate)
        return menu
    }

    private func buildMenu(for event: NSEvent) -> NSMenu? {
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
            add(L("Открыть"), #selector(openSelected(_:)))
            if let openWith = OpenWithMenu.item(for: selectedURLs) { menu.addItem(openWith) }
            menu.addItem(.separator())
            add(L("Копировать путь"), #selector(copyPath(_:)))
            menu.addItem(.separator())
            add(L("Извлечь «%@»", items[i].name), #selector(moveToTrash(_:)))
            menu.addItem(.separator())
            add(L("Свойства"), #selector(showProperties(_:)))
            return menu
        }

        if let i = index(at: point) {
            if !selection.contains(i) { selection = [i]; needsDisplay = true }
            FileContextMenu.addItems(to: menu, for: selectedFileURLs, target: self, folderTabs: false,
                                     customizableFolder: selection.count == 1 && items[i].isFolder)
            // Fences: put the selection into a new one, or take it out of its fence
            let fenceItems = !FenceStyle.enabled ? [] : [
                NSMenuItem(title: L("Поместить в новую зону"), action: #selector(fenceFromSelection(_:)), keyEquivalent: ""),
            ] + (selection.contains { fenceOf[$0] != nil }
                ? [NSMenuItem(title: L("Убрать из зоны"), action: #selector(removeSelectionFromFence(_:)), keyEquivalent: "")] : [])
            if !fenceItems.isEmpty, let properties = menu.items.lastIndex(where: { $0.action == #selector(FileMenuActions.showProperties(_:)) }) {
                var at = properties
                for item in fenceItems { item.target = self; menu.insertItem(item, at: at); at += 1 }
                menu.insertItem(.separator(), at: at)
            }
            return menu
        }

        selection = []
        needsDisplay = true

        // Inside a fence: its own commands first
        if let fence = fence(at: point) {
            fenceMenuItems(for: fence.id).forEach(menu.addItem)
            menu.addItem(.separator())
        }

        let viewMenu = NSMenu()
        for size in DesktopIconSize.allCases {
            add(size.title, #selector(setIconSize(_:)), to: viewMenu, state: layout.iconSize == size, tag: size.rawValue)
        }
        viewMenu.addItem(.separator())
        add(L("Упорядочить значки автоматически"), #selector(toggleAutoArrange(_:)), to: viewMenu, state: layout.autoArrange)
        add(L("Выровнять значки по сетке"), #selector(toggleAlignToGrid(_:)), to: viewMenu, state: layout.alignToGrid)
        viewMenu.addItem(.separator())
        add(L("Отображать значки рабочего стола"), #selector(toggleShowIcons(_:)), to: viewMenu, state: layout.showIcons)
        menu.addItem(withTitle: L("Вид"), action: nil, keyEquivalent: "").submenu = viewMenu

        let sortMenu = NSMenu()
        for (n, key) in DesktopSortKey.allCases.enumerated() {
            add(key.title, #selector(sortBy(_:)), to: sortMenu, state: layout.autoArrange && layout.sortKey == key ? true : nil, tag: n)
        }
        menu.addItem(withTitle: L("Сортировка"), action: nil, keyEquivalent: "").submenu = sortMenu
        add(L("Обновить"), #selector(refreshAction(_:)))
        menu.addItem(.separator())
        // Like Finder: only when there's something to paste (context menus hide what can't be done)
        if FileClipboard.shared.canPaste {
            add(L("Вставить"), #selector(paste(_:)))
            menu.addItem(.separator())
        }
        menu.addItem(NewItemTemplate.menuItem(target: self, action: #selector(createNewItem(_:))))
        if FenceStyle.enabled, fence(at: point) == nil {
            add(L("Создать зону"), #selector(createFence(_:)))
            add(L("Создать портал папки…"), #selector(createPortal(_:)))
        }
        menu.addItem(.separator())
        if let terminal = TerminalLauncher.menuItem(for: [desktopURL]) { menu.addItem(terminal) }
        OpenWithMenu.mainMenuItems(for: [desktopURL]).forEach(menu.addItem)
        add(L("Обои…"), #selector(openWallpaperSettings(_:)))
        menu.addItem(withTitle: L("Настройки WinEx…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
            .target = AppDelegate.shared
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paste(_:)): return FileClipboard.shared.canPaste
        case #selector(cut(_:)), #selector(copy(_:)), #selector(duplicate(_:)), #selector(compress(_:)),
             #selector(makeAlias(_:)): return !selection.isEmpty
        case #selector(showOriginal(_:)): return selectedFileURLs.contains(where: FileCommands.isAlias)
        case #selector(showPackageContents(_:)): return selectedFileURLs.contains(where: FileCommands.isPackage)
        case #selector(extractArchive(_:)): return selectedFileURLs.contains(where: FileCommands.isZip)
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

    // MARK: Finder file commands

    @objc func duplicate(_ sender: Any?) { FileCommands.duplicate(selectedFileURLs) }
    @objc func compress(_ sender: Any?) { FileCommands.compress(selectedFileURLs) }
    @objc func makeAlias(_ sender: Any?) { FileCommands.makeAliases(selectedFileURLs) }
    @objc func extractArchive(_ sender: Any?) { selectedFileURLs.filter(FileCommands.isZip).forEach(FileCommands.extract) }

    @objc func showOriginal(_ sender: Any?) {
        guard let url = selectedFileURLs.first else { return }
        FileCommands.showOriginal(of: url) { AppDelegate.shared.reveal($0) }
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let url = selectedFileURLs.first(where: FileCommands.isPackage) else { return }
        AppDelegate.shared.openWindow(at: url.deletingLastPathComponent()).browse(url)
    }
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
        // The panel zooms from / back into the same rounded preview the desktop shows
        return image
    }
    @objc func copyPath(_ sender: Any?) { FileOps.copyPaths(selectedURLs) }
    @objc func moveToTrash(_ sender: Any?) { trashSelection() }
    @objc private func refreshAction(_ sender: Any?) { reload() }

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

    // MARK: - Fences

    /// The fences of this monitor (a fence of a monitor that isn't connected shows on the main one).
    private var myFences: [DesktopFence] {
        guard FenceStyle.enabled else { return [] }
        let here = screens.first?.id
        return layout.fences.filter { connectedScreenIDs.contains($0.screenID) ? $0.screenID == here : isMain }
    }

    /// Fences of a monitor that isn't connected, shown here for now: where they go so they don't
    /// cover this monitor's own fences (their stored place is kept for when the monitor returns).
    private var displacedFrames: [String: NSRect] = [:]

    private func placeDisplacedFences() {
        displacedFrames = [:]
        guard let area = screens.first?.iconArea else { return }
        let here = screens.first?.id
        let fences = myFences
        var taken = fences.filter { $0.screenID == here }.map { visibleFrame(of: $0, whole: true).insetBy(dx: -FenceSnap.gap, dy: -FenceSnap.gap) }
        for fence in fences where fence.screenID != here {
            var frame = visibleFrame(of: fence, whole: true)
            if taken.contains(where: { $0.intersects(frame) }) {
                // The nearest free spot, scanning the monitor in steps
                var best: NSRect?
                var bestDistance = CGFloat.greatestFiniteMagnitude
                let step: CGFloat = 24
                var y = area.minY + FenceSnap.gap
                while y + frame.height <= area.maxY - FenceSnap.gap {
                    var x = area.minX + FenceSnap.gap
                    while x + frame.width <= area.maxX - FenceSnap.gap {
                        let candidate = NSRect(x: x, y: y, width: frame.width, height: frame.height)
                        if !taken.contains(where: { $0.intersects(candidate) }) {
                            let distance = hypot(candidate.minX - frame.minX, candidate.minY - frame.minY)
                            if distance < bestDistance { bestDistance = distance; best = candidate }
                        }
                        x += step
                    }
                    y += step
                }
                // No room at all: cascaded, at least not exactly on top
                frame = best ?? frame.offsetBy(dx: CGFloat(displacedFrames.count + 1) * 30, dy: CGFloat(displacedFrames.count + 1) * 30)
                displacedFrames[fence.id] = frame
            }
            taken.append(frame.insetBy(dx: -FenceSnap.gap, dy: -FenceSnap.gap))
        }
    }

    /// A fence's frame as shown: kept inside the monitor; just the title bar when rolled up
    /// (unless `whole`: the place it takes either way).
    private func visibleFrame(of fence: DesktopFence, whole: Bool = false) -> NSRect {
        guard let area = screens.first?.iconArea else { return fence.frame }
        if var moved = displacedFrames[fence.id] {
            if fence.collapsed && !whole { moved.size.height = DesktopFence.titleHeight }
            return moved
        }
        var frame = fence.frame
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        if fence.collapsed && !whole { frame.size.height = DesktopFence.titleHeight }
        return frame
    }

    /// Where a fence's icons go: its inside, the number of columns and of whole rows.
    private func fenceGrid(_ fence: DesktopFence) -> (content: NSRect, columns: Int, rows: Int) {
        let frame = visibleFrame(of: fence)
        var content = frame.insetBy(dx: DesktopFence.padding, dy: DesktopFence.padding)
        content.origin.y += DesktopFence.titleHeight - DesktopFence.padding
        content.size.height -= DesktopFence.titleHeight - DesktopFence.padding
        let columns = max(1, Int(content.width / fenceCell.width))
        let rows = max(0, Int((content.height - fenceTopExtra) / fenceCell.height))
        return (content, columns, rows)
    }

    /// Icons sit as far from the fence's top as from its left side (a cell is wider than its icon).
    private var fenceTopExtra: CGFloat { max(0, (fenceCell.width - iconSide) / 2 + DesktopFence.padding - 8) }

    /// A fence's cells are a bit tighter than the desktop's (three quarters of the room beside the
    /// icon), leaving the labels room to breathe.
    private var fenceCell: NSSize {
        NSSize(width: (iconSide + (cellSize.width - iconSide) * 0.75).rounded(), height: cellSize.height - 4)
    }

    /// Puts the icons of this monitor's fences into their fences (in their order, row by row).
    private func layoutFences() {
        hiddenIcons = []
        fenceOf = [:]
        fenceClip = [:]
        placeDisplacedFences()
        for fence in myFences where !fence.isPortal {
            let grid = fenceGrid(fence)
            let members = fence.members.compactMap(index(named:))
            let offset = min(fenceScroll[fence.id] ?? 0, maxScroll(fence))
            fenceScroll[fence.id] = offset
            // Icons show under the title bar, down to the fence's bottom edge
            let frame = visibleFrame(of: fence)
            let clip = NSRect(x: frame.minX, y: frame.minY + DesktopFence.titleHeight, width: frame.width,
                              height: max(0, frame.height - DesktopFence.titleHeight - 1))
            for (k, i) in members.enumerated() {
                fenceOf[i] = fence.id
                let row = k / grid.columns, column = k % grid.columns
                centers[i] = CGPoint(x: grid.content.minX + fenceCell.width * (CGFloat(column) + 0.5),
                                     y: grid.content.minY + fenceTopExtra + iconSide / 2 + 8 + fenceCell.height * CGFloat(row) - offset)
                if fence.collapsed || !hitRect(i).intersects(clip) { hiddenIcons.insert(i) } else { fenceClip[i] = clip }
            }
        }
    }

    /// The fence whose area (or, rolled up, title) is at `point`.
    private func fence(at point: NSPoint) -> DesktopFence? {
        guard !quickHidden else { return nil }
        return myFences.last { visibleFrame(of: $0).contains(point) }
    }

    private func syncFenceViews() {
        let fences = myFences
        for (id, view) in fenceViews where !fences.contains(where: { $0.id == id }) {
            view.removeFromSuperview()
            fenceViews[id] = nil
        }
        for fence in fences {
            let isNew = fenceViews[fence.id] == nil
            let view = fenceViews[fence.id] ?? makeFenceView(fence)
            if isNew && quickHidden { view.alphaValue = 0 }
            view.fence = fence
            if view.window == nil || (!isDraggingFence(fence.id) && animatingFence != fence.id) { view.frame = visibleFrame(of: fence) }
            let grid = fenceGrid(fence)
            let count = fence.members.filter { index(named: $0) != nil }.count
            let most = maxScroll(fence)
            view.scroller = fence.collapsed || most <= 0 ? nil
                : (offset: fenceScroll[fence.id] ?? 0, content: grid.content.height + most, visible: grid.content.height)
            view.configurePortal(cell: fenceCell, iconSide: iconSide)
            view.minimumSize = NSSize(width: fenceCell.width + 2 * DesktopFence.padding,
                                      height: DesktopFence.titleHeight + fenceTopExtra + fenceCell.height + DesktopFence.padding)
        }
    }

    private var draggingFence: String?
    private func isDraggingFence(_ id: String) -> Bool { draggingFence == id }

    private func makeFenceView(_ fence: DesktopFence) -> FenceView {
        let view = FenceView(fence: fence)
        let id = fence.id
        view.snap = { [weak self] rect, edges in
            guard let self, let area = self.screens.first?.iconArea else { return (rect, []) }
            // Snapping targets: this monitor's edges and its other fences only (not icons or widgets)
            let others = self.myFences.filter { $0.id != id }.map { self.visibleFrame(of: $0) }
            var (snapped, guides) = FenceSnap.snap(rect, edges: edges, area: area, others: others)
            // Resizing: a light pull towards sizes that hold whole columns and rows of icons
            // (unless an edge already clings to something)
            if edges.count < 4 {
                let pull: CGFloat = 10
                let columnsWidth = { (n: CGFloat) in n * self.fenceCell.width + 2 * DesktopFence.padding }
                let rowsHeight = { (n: CGFloat) in DesktopFence.titleHeight + self.fenceTopExtra + n * self.fenceCell.height + DesktopFence.padding }
                let widthTarget = columnsWidth(max(1, ((snapped.width - 2 * DesktopFence.padding) / self.fenceCell.width).rounded()))
                let heightTarget = rowsHeight(max(1, ((snapped.height - DesktopFence.titleHeight - self.fenceTopExtra - DesktopFence.padding) / self.fenceCell.height).rounded()))
                let horizontal = guides.contains { $0.vertical }, vertical = guides.contains { !$0.vertical }
                if !horizontal, abs(snapped.width - widthTarget) <= pull, edges.contains(.minX) || edges.contains(.maxX) {
                    if edges.contains(.minX) { snapped.origin.x = snapped.maxX - widthTarget }
                    snapped.size.width = widthTarget
                }
                if !vertical, abs(snapped.height - heightTarget) <= pull, edges.contains(.minY) || edges.contains(.maxY) {
                    if edges.contains(.minY) { snapped.origin.y = snapped.maxY - heightTarget }
                    snapped.size.height = heightTarget
                }
            }
            return (snapped, guides)
        }
        view.onGuides = { [weak self] guides in self?.guidesView.guides = guides }
        view.onFrame = { [weak self] frame, final in
            guard let self, var fence = self.layout.fences.first(where: { $0.id == id }) else { return }
            self.draggingFence = final ? nil : id
            // Moved by hand: it belongs to this monitor now, where it was put
            if self.displacedFrames[id] != nil, let here = self.screens.first?.id { fence.screenID = here; self.displacedFrames[id] = nil }
            if fence.collapsed {
                fence.frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: fence.height)
            } else {
                fence.frame = frame
            }
            self.layout.setFence(fence, save: final)
            self.relayout()
        }
        view.onToggleCollapsed = { [weak self] in self?.toggleCollapsed(id) }
        view.onRename = { [weak self] title in
            guard let self, var fence = self.layout.fences.first(where: { $0.id == id }) else { return }
            fence.title = title
            self.layout.setFence(fence)
            self.needsDisplay = true
        }
        view.onMenu = { [weak self] _ in
            guard let self else { return nil }
            let menu = NSMenu()
            self.fenceMenuItems(for: id).forEach(menu.addItem)
            MenuStyle.decorate(menu)
            return menu
        }
        addSubview(view, positioned: .below, relativeTo: nil)
        fenceViews[id] = view
        return view
    }

    private func fenceMenuItems(for id: String) -> [NSMenuItem] {
        guard let fence = layout.fences.first(where: { $0.id == id }) else { return [] }
        func item(_ title: String, _ action: Selector, _ symbol: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }
        var items: [NSMenuItem] = []
        if fence.isPortal {
            items.append(item(L("Открыть папку в WinEx"), #selector(openPortalFolder(_:)), "folder"))
            items.append(item(L("Другая папка…"), #selector(changePortalFolder(_:)), "folder.badge.gearshape"))
            items.append(.separator())
        }
        if !fence.isPortal { items.append(item(L("Переименовать зону"), #selector(renameFence(_:)), "pencil")) }
        // Its own colour, or the one from Settings
        let colors = NSMenu()
        let standard = colors.addItem(withTitle: L("Как в настройках"), action: #selector(setFenceColor(_:)), keyEquivalent: "")
        standard.target = self
        standard.representedObject = [id, ""]
        standard.state = fence.color == nil ? .on : .off
        // The colour from Settings, in a dashed ring (lines up with the swatches below)
        standard.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            (FenceStyle.nsColor(FenceStyle.color) ?? .black).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3.5, dy: 3.5)).fill()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1
            ring.setLineDash([2, 1.5], count: 2, phase: 0)
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            ring.stroke()
            return true
        }
        colors.addItem(.separator())
        for hex in FenceStyle.presets {
            let swatch = colors.addItem(withTitle: hex, action: #selector(setFenceColor(_:)), keyEquivalent: "")
            swatch.target = self
            swatch.representedObject = [id, hex]
            swatch.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                (FenceStyle.nsColor(hex) ?? .black).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                NSColor.labelColor.withAlphaComponent(0.3).setStroke()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
                return true
            }
            swatch.state = fence.color == hex ? .on : .off
        }
        let colorItem = item(L("Цвет зоны"), #selector(noop(_:)), "paintpalette")
        colorItem.action = nil
        colorItem.submenu = colors
        items.append(colorItem)
        items.append(item(L("Удалить зону"), #selector(deleteFence(_:)), "rectangle.badge.xmark"))
        return items
    }

    /// Several icons selected (not all of one fence already): the hint to fence them, under them.
    private func updateFenceHint() {
        let chosen = selection.filter { !hiddenIcons.contains($0) && items.indices.contains($0) }
        let sameFence = Set(chosen.map { fenceOf[$0] ?? "" }).count == 1 && chosen.allSatisfy { fenceOf[$0] != nil }
        let ready = FenceStyle.enabled && rubberBand == nil && !dragStarted && iconsVisible && renameField == nil
        let forSelection = ready && chosen.count >= 2 && !sameFence
        if !chosen.isEmpty { emptyArea = nil }
        let area = ready ? emptyArea : nil
        // The empty area, outlined
        if let area {
            areaOutline.frame = area
            addSubview(areaOutline, positioned: .above, relativeTo: nil)
        } else if areaOutline.superview != nil {
            areaOutline.removeFromSuperview()
        }
        guard forSelection || area != nil else {
            if fenceHint.superview != nil {
                fenceHint.removeFromSuperview()
                fenceHint.alphaValue = 0
            }
            return
        }
        if fenceHint.superview == nil {
            fenceHint.alphaValue = 0
            addSubview(fenceHint)
        }
        addSubview(fenceHint, positioned: .above, relativeTo: nil)
        var box: NSRect
        if let area {
            fenceHint.configure(title: L("Создать зону здесь"), tip: L("Пустая зона на месте выделенной области"))
            fenceHint.onClick = { [weak self] in self?.makeFence(in: area) }
            box = area
        } else {
            fenceHint.configure(title: L("Поместить в зону"), tip: L("Объединить выделенные значки в зону"))
            fenceHint.onClick = { [weak self] in self?.fenceFromSelection(nil) }
            // Under the selection when it's a group; spread out — under its lowest icon
            box = chosen.map(hitRect).reduce(NSRect.null) { $0.union($1) }
            if box.width > cellSize.width * 5 || box.height > cellSize.height * 4,
               let lowest = chosen.max(by: { centers[$0].y < centers[$1].y }) { box = hitRect(lowest) }
        }
        let size = fenceHint.intrinsicContentSize
        let screenArea = screens.first?.iconArea ?? bounds
        var origin = NSPoint(x: box.midX - size.width / 2, y: box.maxY + 10)
        if origin.y + size.height > screenArea.maxY - 8 { origin.y = box.minY - size.height - 10 }
        origin.x = min(max(origin.x, screenArea.minX + 8), screenArea.maxX - size.width - 8)
        fenceHint.frame = NSRect(origin: origin, size: size)
        if fenceHint.alphaValue < 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.18; fenceHint.animator().alphaValue = 1 } }
    }

    // MARK: Quick-hide

    private(set) var quickHidden = false

    /// Hides every icon and fence of this monitor with a fade (or brings them back).
    var quickHideChange: ((DesktopView, Bool) -> Void)?

    func setQuickHidden(_ hidden: Bool, fromOtherMonitor: Bool = false) {
        guard hidden != quickHidden else { return }
        if !fromOtherMonitor { quickHideChange?(self, hidden) }
        quickHidden = hidden
        selection = []
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            (tiles + Array(fenceViews.values) as [NSView]).forEach { $0.animator().alphaValue = hidden ? 0 : 1 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    private func highlightFence(_ id: String?) {
        for (fenceID, view) in fenceViews { view.isDropTarget = fenceID == id }
    }

    /// Puts icons into a fence (out of any other one), before the icon nearest to `point`.
    private func addToFence(_ id: String, names: [String], at point: NSPoint? = nil, relayoutNow: Bool = true) {
        var fences = layout.fences
        guard let target = fences.firstIndex(where: { $0.id == id }) else { return }
        for n in fences.indices { fences[n].members.removeAll { names.contains($0) } }
        var position = fences[target].members.count
        if let point, !fences[target].collapsed {
            let grid = fenceGrid(fences[target])
            let column = min(max(Int((point.x - grid.content.minX) / fenceCell.width), 0), grid.columns - 1)
            let row = max(Int((point.y - grid.content.minY - fenceTopExtra + (fenceScroll[id] ?? 0)) / fenceCell.height), 0)
            position = min(row * grid.columns + column, fences[target].members.count)
        }
        fences[target].members.insert(contentsOf: names, at: position)
        // The icons live on this fence's monitor now
        let center = CGPoint(x: fences[target].frame.midX, y: fences[target].frame.midY)
        for name in names { setPlacement(center, forName: name) }
        layout.save()
        layout.fences = fences
        if relayoutNow { reload() }
        sharedChange?(self)
    }

    private func removeFromFences(_ names: [String]) {
        let fences = layout.fences
        guard fences.contains(where: { !Set($0.members).isDisjoint(with: names) }) else { return }
        layout.fences = fences.map { fence in
            var fence = fence
            fence.members.removeAll { names.contains($0) }
            return fence
        }
    }

    private var animatingFence: String?

    /// Rolls a fence up (its icons fade, the panel folds into its title) or down (the reverse).
    private func toggleCollapsed(_ id: String) {
        guard var fence = layout.fences.first(where: { $0.id == id }), let view = fenceViews[id] else { return }
        let memberTiles = { [self] in fenceOf.filter { $0.value == id }.map(\.key).filter(tiles.indices.contains).map { tiles[$0] } }
        fence.collapsed.toggle()
        selection = selection.filter { fenceOf[$0] != id }
        animatingFence = id
        if fence.collapsed {
            let fading = memberTiles()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fading.forEach { $0.animator().alphaValue = 0 }
                view.animator().frame = visibleFrame(of: fence)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.animatingFence = nil
                    self.layout.setFence(fence)
                    self.relayout()
                    fading.forEach { $0.alphaValue = 1 }
                }
            }
        } else {
            layout.setFence(fence)
            relayout()
            // Transparent before they're drawn at all, then they fade in as the panel unfolds
            let appearing = memberTiles()
            appearing.forEach { $0.alphaValue = 0 }
            displayIfNeeded()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().frame = visibleFrame(of: fence)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.animatingFence = nil; self?.needsDisplay = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    appearing.forEach { $0.animator().alphaValue = 1 }
                }
            }
        }
    }

    /// A new fence of a sensible size at `point` (snapped), then its title is edited.
    /// An empty zone where the area was selected (snapped to the edges and other zones).
    private func makeFence(in area: NSRect) {
        guard let screen = screens.first else { return }
        emptyArea = nil
        let others = myFences.map { visibleFrame(of: $0) }
        let rect = FenceSnap.snap(area, edges: [.minX, .maxX, .minY, .maxY], area: screen.iconArea, others: others).0
        var fence = DesktopFence(title: L("Новая зона"), screenID: screen.id, x: 0, y: 0, width: 0, height: 0)
        fence.frame = rect.integral
        layout.setFence(fence)
        relayout()
        selection = []
        DispatchQueue.main.async { [weak self] in self?.fenceViews[fence.id]?.beginRename() }
    }

    private func makeFence(at point: NSPoint, members: [String]) {
        guard let screen = screens.first else { return }
        let columns = max(3, min(4, members.count))
        let rows = max(2, Int(ceil(Double(members.count) / Double(columns))))
        let size = NSSize(width: CGFloat(columns) * fenceCell.width + 2 * DesktopFence.padding,
                          height: DesktopFence.titleHeight + fenceTopExtra + CGFloat(rows) * fenceCell.height + DesktopFence.padding)
        var rect = NSRect(origin: NSPoint(x: point.x - 20, y: point.y - 10), size: size)
        let others = myFences.map { visibleFrame(of: $0) }
        rect.origin.x = min(max(rect.minX, screen.iconArea.minX + FenceSnap.gap), screen.iconArea.maxX - rect.width - FenceSnap.gap)
        rect.origin.y = min(max(rect.minY, screen.iconArea.minY + FenceSnap.gap), screen.iconArea.maxY - rect.height - FenceSnap.gap)
        rect = FenceSnap.snap(rect, edges: [.minX, .maxX, .minY, .maxY], area: screen.iconArea, others: others).0
        var fence = DesktopFence(title: L("Новая зона"), screenID: screen.id, x: 0, y: 0, width: 0, height: 0)
        fence.frame = rect.integral
        layout.setFence(fence)
        if !members.isEmpty { addToFence(fence.id, names: members) } else { relayout() }
        selection = []
        DispatchQueue.main.async { [weak self] in self?.fenceViews[fence.id]?.beginRename() }
    }

    @objc private func noop(_ sender: Any?) {}

    @objc private func setFenceColor(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              var fence = layout.fences.first(where: { $0.id == pair[0] }) else { return }
        fence.color = pair[1].isEmpty ? nil : pair[1]
        layout.setFence(fence)
        syncFenceViews()
    }

    /// A portal: a fence showing a folder (chosen now) on the desktop.
    @objc private func createPortal(_ sender: Any?) {
        let point = menuPoint ?? NSPoint(x: bounds.midX, y: bounds.midY)
        chooseFolder { [weak self] folder in
            guard let self, let screen = self.screens.first else { return }
            let size = NSSize(width: 4 * self.fenceCell.width + 2 * DesktopFence.padding,
                              height: DesktopFence.titleHeight + self.fenceTopExtra + 2 * self.fenceCell.height + DesktopFence.padding)
            var rect = NSRect(origin: NSPoint(x: point.x - 20, y: point.y - 10), size: size)
            rect.origin.x = min(max(rect.minX, screen.iconArea.minX + FenceSnap.gap), screen.iconArea.maxX - rect.width - FenceSnap.gap)
            rect.origin.y = min(max(rect.minY, screen.iconArea.minY + FenceSnap.gap), screen.iconArea.maxY - rect.height - FenceSnap.gap)
            rect = FenceSnap.snap(rect, edges: [.minX, .maxX, .minY, .maxY], area: screen.iconArea, others: self.myFences.map { self.visibleFrame(of: $0) }).0
            var fence = DesktopFence(title: folder.displayName, screenID: screen.id, x: 0, y: 0, width: 0, height: 0)
            fence.frame = rect.integral
            fence.portalPath = folder.path
            self.layout.setFence(fence)
            self.relayout()
        }
    }

    private func chooseFolder(_ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Выбрать")
        panel.message = L("Папка, содержимое которой будет видно на рабочем столе")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        done(url)
    }

    @objc private func openPortalFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let path = layout.fences.first(where: { $0.id == id })?.portalPath else { return }
        AppDelegate.shared.openWindow(at: URL(fileURLWithPath: path))
    }

    @objc private func changePortalFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        chooseFolder { [weak self] folder in
            guard let self, var fence = self.layout.fences.first(where: { $0.id == id }) else { return }
            if fence.title == URL(fileURLWithPath: fence.portalPath ?? "").displayName { fence.title = folder.displayName }
            fence.portalPath = folder.path
            self.layout.setFence(fence)
            self.relayout()
        }
    }

    @objc private func createFence(_ sender: Any?) {
        makeFence(at: menuPoint ?? NSPoint(x: bounds.midX, y: bounds.midY), members: [])
    }

    @objc private func fenceFromSelection(_ sender: Any?) {
        let chosen = selection.sorted()
        guard let first = chosen.first else { return }
        let origin = CGPoint(x: chosen.map { centers[$0].x }.min() ?? centers[first].x, y: chosen.map { centers[$0].y }.min() ?? centers[first].y)
        makeFence(at: NSPoint(x: origin.x - cellSize.width / 2, y: origin.y - iconSide / 2 - DesktopFence.titleHeight), members: chosen.map(name(of:)))
    }

    @objc private func removeSelectionFromFence(_ sender: Any?) {
        let names = selection.map(name(of:))
        // They stay where they are on screen, now as desktop icons
        for i in selection where fenceOf[i] != nil { storePosition(of: i) }
        layout.save()
        removeFromFences(names)
        relayout()
    }

    @objc private func renameFence(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        fenceViews[id]?.beginRename()
    }

    /// The fence goes; its icons stay where they are, as desktop icons.
    @objc private func deleteFence(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        for (i, fenceID) in fenceOf where fenceID == id && !hiddenIcons.contains(i) { storePosition(of: i) }
        layout.save()
        layout.fences = layout.fences.filter { $0.id != id }
        relayout()
    }

    #if DEBUG
    /// Scenario hooks.
    func debugMakeFence(at point: NSPoint, members: [String]) -> String? {
        makeFence(at: point, members: members)
        return layout.fences.last?.id
    }
    func debugFenceView(_ id: String) -> FenceView? { fenceViews[id] }
    func debugIsHidden(_ name: String) -> Bool { index(named: name).map { hiddenIcons.contains($0) } ?? true }
    func debugToggle(_ id: String) { toggleCollapsed(id) }
    func debugSetFenceFrame(_ id: String, _ frame: NSRect) {
        guard var fence = layout.fences.first(where: { $0.id == id }) else { return }
        fence.frame = frame
        layout.setFence(fence)
        relayout()
    }
    func debugScroll(_ id: String) -> CGFloat { fenceScroll[id] ?? 0 }
    var debugCellHeight: CGFloat { fenceCell.height }
    /// The hint's title when it's shown ("" when not), and a click on it.
    var debugHintTitle: String { fenceHint.superview != nil ? (fenceHint.toolTip ?? "") : "" }
    func debugClickHint() { fenceHint.onClick?() }
    /// The first empty spot at least `size` big (none of it under icons, zones or widgets).
    func debugEmptySpot(_ size: NSSize) -> NSRect? {
        guard let area = screens.first?.iconArea else { return nil }
        var y = area.minY + 20
        while y + size.height < area.maxY {
            var x = area.minX + 20
            while x + size.width < area.maxX {
                let rect = NSRect(origin: NSPoint(x: x, y: y), size: size)
                let taken = items.indices.contains { !hiddenIcons.contains($0) && hitRect($0).insetBy(dx: -8, dy: -8).intersects(rect) }
                    || blockedRects.contains { $0.intersects(rect) }
                if !taken { return rect }
                x += 20
            }
            y += 20
        }
        return nil
    }
    /// As if the colour was picked in the fence's menu.
    func debugSetColor(_ id: String, _ hex: String) {
        let item = NSMenuItem()
        item.representedObject = [id, hex]
        setFenceColor(item)
    }
    /// Stores `name` at `point` (as if dragged there before the fence existed) and lays out again.
    func debugPlace(_ name: String, at point: CGPoint) { setPlacement(point, forName: name); relayout() }
    func debugMakePortal(_ folder: URL, at point: NSPoint) -> String? {
        guard let screen = screens.first else { return nil }
        var fence = DesktopFence(title: folder.displayName, screenID: screen.id, x: 0, y: 0, width: 0, height: 0)
        fence.frame = NSRect(x: point.x, y: point.y, width: 4 * fenceCell.width + 2 * DesktopFence.padding,
                             height: DesktopFence.titleHeight + fenceTopExtra + 2 * fenceCell.height + DesktopFence.padding)
        fence.portalPath = folder.path
        layout.setFence(fence)
        relayout()
        return fence.id
    }
    func debugSelect(_ names: [String]) { selection = Set(names.compactMap(index(named:))); needsDisplay = true }
    #endif

    // MARK: - Inline rename

    private func beginRename(_ index: Int) {
        endRename()
        let item = items[index]
        let field = NSTextField(frame: labelRect(index).insetBy(dx: -8, dy: -2))
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

    /// Only the part inside `rect` (in the desktop's coordinates) shows: an icon scrolled halfway out
    /// of its fence is cut off at the fence's edge.
    func clip(to rect: NSRect?) {
        guard let rect, !rect.contains(frame) else {
            layer?.mask = nil
            return
        }
        wantsLayer = true
        var visible = rect.intersection(frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
        if layer?.contentsAreFlipped() == false { visible.origin.y = bounds.height - visible.maxY }
        let mask = (layer?.mask) ?? CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = visible
        CATransaction.commit()
        layer?.mask = mask
    }

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
