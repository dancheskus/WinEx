import AppKit
import QuickLookThumbnailing

/// Where a stack opens: the point on the Dock's edge by the clicked tile.
struct StackAnchor {
    enum Edge { case bottom, left, right }
    var point: NSPoint
    var edge: Edge
    /// The screen's area without the menu bar (and the Dock), and the whole screen.
    var visible: NSRect
    var frame: NSRect
    /// The stack's tile in the Dock (screen coordinates), for the arrow drawn over it while open.
    var tile: NSRect?

    /// From where the mouse was on the tile: the Dock's side and size from its settings; the
    /// tile itself from the Dock (Accessibility, when WinEx may use it), else around the mouse.
    @MainActor
    static func at(_ mouse: NSPoint, app: URL? = nil) -> StackAnchor {
        let screens = NSScreen.screens
        let screen = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = screen?.visibleFrame ?? frame
        let dock = "com.apple.dock" as CFString
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, dock) as? String ?? "bottom"
        let side = CGFloat((CFPreferencesCopyAppValue("tilesize" as CFString, dock) as? NSNumber)?.doubleValue ?? 48)
        let found = app.flatMap(dockTileFrame)
        let center = found.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouse
        // The Dock's edge: where the visible area ends; a hidden Dock leaves none — its tiles' top
        var anchor: StackAnchor
        var guess: NSRect
        switch orientation {
        case "left":
            let x = visible.minX > frame.minX + 2 ? visible.minX : mouse.x + side / 2 + 6
            anchor = StackAnchor(point: NSPoint(x: x, y: center.y), edge: .left, visible: visible, frame: frame)
            let mid = visible.minX > frame.minX + 2 ? (frame.minX + visible.minX) / 2 : mouse.x
            guess = NSRect(x: mid - side / 2, y: mouse.y - side / 2, width: side, height: side)
        case "right":
            let x = visible.maxX < frame.maxX - 2 ? visible.maxX : mouse.x - side / 2 - 6
            anchor = StackAnchor(point: NSPoint(x: x, y: center.y), edge: .right, visible: visible, frame: frame)
            let mid = visible.maxX < frame.maxX - 2 ? (frame.maxX + visible.maxX) / 2 : mouse.x
            guess = NSRect(x: mid - side / 2, y: mouse.y - side / 2, width: side, height: side)
        default:
            let y = visible.minY > frame.minY + 2 ? visible.minY : mouse.y + side / 2 + 6
            anchor = StackAnchor(point: NSPoint(x: center.x, y: y), edge: .bottom, visible: visible, frame: frame)
            let mid = visible.minY > frame.minY + 2 ? (frame.minY + visible.minY) / 2 : mouse.y
            guess = NSRect(x: mouse.x - side / 2, y: mid - side / 2, width: side, height: side)
        }
        anchor.tile = found ?? (app != nil ? guess : nil)
        return anchor
    }

    /// The Dock's tile of `app` (screen coordinates), read through Accessibility.
    @MainActor
    static func dockTileFrame(_ app: URL) -> NSRect? {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        let wanted = app.standardizedFileURL.path.trimmingCharacters(in: ["/"])
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        for list in value(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            for tile in value(list, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard let url = value(tile, kAXURLAttribute) as? NSURL, (url as URL).standardizedFileURL.path.trimmingCharacters(in: ["/"]) == wanted,
                      let position = value(tile, kAXPositionAttribute), let size = value(tile, kAXSizeAttribute),
                      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
                var point = CGPoint.zero, extent = CGSize.zero
                // (Checked above: they are AXValues)
                AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point)
                AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent)
                // Accessibility counts from the top of the main screen
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                return NSRect(x: point.x, y: top - point.y - extent.height, width: extent.width, height: extent.height)
            }
        }
        return nil
    }

    /// Room above the Dock (to the side of a side Dock).
    var room: NSRect {
        switch edge {
        case .bottom: return NSRect(x: frame.minX, y: point.y, width: frame.width, height: visible.maxY - point.y)
        case .left: return NSRect(x: point.x, y: visible.minY, width: frame.maxX - point.x, height: visible.height)
        case .right: return NSRect(x: frame.minX, y: visible.minY, width: point.x - frame.minX, height: visible.height)
        }
    }
}

/// One thing in a stack: a file or folder, or the stack's last item, «Открыть в WinEx» (with
/// how many items the fan had no room for).
struct StackEntry {
    var item: FileItem?
    var more = 0

    var title: String {
        guard let item else { return more > 0 ? L("Ещё %@ в WinEx", more) : L("Открыть в WinEx") }
        return item.name
    }
}

/// The Dock's stack of a folder, drawn by WinEx above its tile: a fan, a grid (into folders and
/// back, scrolling) or a list (a menu); it closes on a click elsewhere, Esc, opening something.
@MainActor
final class DockStackPanel: NSPanel {
    private(set) static var current: DockStackPanel?
    /// The stack closed by a click outside it: a click on its tile closes it (the tile's click
    /// arrives right after), it doesn't open it again.
    private static var lastClosed: (id: String, at: Date)?

    let stack: DockStack
    let anchor: StackAnchor
    let root: URL
    private(set) var folder: URL
    private var monitors: [Any] = []
    private let observers = Observers()
    private var followed: URL?
    private var dragging = false

    static func toggle(_ stack: DockStack, folder: URL, mouse: NSPoint) {
        if let current, current.stack.id == stack.id { current.dismiss(); return }
        if let last = lastClosed, last.id == stack.id, Date().timeIntervalSince(last.at) < 0.5 { lastClosed = nil; return }
        current?.dismiss()
        show(stack, folder: folder, anchor: .at(mouse, app: DockStacks.bundleURL(for: stack)))
    }

    /// The folder's items in the stack's order (hidden files left out, as the Dock does).
    static func contents(of folder: URL, sort: FileItem.SortOrder) -> [FileItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: FileItem.keys, options: [.skipsHiddenFiles])) ?? []
        return FileItem.sorted(urls.prefix(5000).map(FileItem.init), by: sort)
    }

    /// How many items a fan has room for: Apple sets no number — the Dock's fan takes what fits
    /// its screen, about a dozen; past that, «Ещё N». The top row (tilted, its pill's end higher)
    /// stays below the menu bar.
    static func fanCapacity(_ anchor: StackAnchor) -> Int {
        var count = 12
        while count > 1, StackFanView.top(rows: count + 1, anchor: anchor) > anchor.visible.maxY - 8 { count -= 1 }
        return count
    }

    static func show(_ stack: DockStack, folder: URL, anchor: StackAnchor) {
        let items = contents(of: folder, sort: stack.sortOrder)
        let fanFits = anchor.edge == .bottom && items.count <= fanCapacity(anchor)
        let view: DockStack.View = stack.view == .automatic ? (fanFits ? .fan : .grid)
            : stack.view == .fan && anchor.edge != .bottom ? .grid : stack.view
        if view == .list {
            StackList.popUp(stack, folder: folder, items: items, anchor: anchor)
            return
        }
        let panel = DockStackPanel(stack: stack, folder: folder, anchor: anchor)
        if view == .fan {
            let capacity = fanCapacity(anchor)
            var entries = items.prefix(capacity).map { StackEntry(item: $0) }
            entries.append(StackEntry(item: nil, more: max(0, items.count - capacity)))
            panel.showFan(entries)
        } else {
            panel.showGrid(items)
        }
        current = panel
        panel.present()
    }

    private init(stack: DockStack, folder: URL, anchor: StackAnchor) {
        self.stack = stack
        self.anchor = anchor
        root = folder
        self.folder = folder
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }

    // MARK: Fan

    private func showFan(_ entries: [StackEntry]) {
        let fan = StackFanView(entries: entries, anchor: anchor)
        setFrame(fan.screenFrame, display: false)
        fan.frame = NSRect(origin: .zero, size: fan.screenFrame.size)
        fan.panel = self
        contentView = fan
        follow(folder)
    }

    // MARK: Grid

    private var grid: StackGridView?

    private func showGrid(_ items: [FileItem]) {
        let grid = StackGridView(panel: self)
        self.grid = grid
        contentView = grid
        grid.show(items, title: FileManager.default.displayName(atPath: folder.path), canGoBack: false)
        follow(folder)
    }

    /// Fits the grid's panel to `size`, by the tile.
    func placeGrid(_ size: NSSize) {
        let room = anchor.room
        var origin = NSPoint.zero
        switch anchor.edge {
        case .bottom:
            origin = NSPoint(x: anchor.point.x - size.width / 2, y: anchor.point.y + 6)
        case .left:
            origin = NSPoint(x: anchor.point.x + 6, y: anchor.point.y - size.height / 2)
        case .right:
            origin = NSPoint(x: anchor.point.x - size.width - 6, y: anchor.point.y - size.height / 2)
        }
        origin.x = min(max(origin.x, room.minX + 8), room.maxX - size.width - 8)
        origin.y = min(max(origin.y, room.minY + 6), room.maxY - size.height - 6)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Into a folder of the grid (or back up), the panel resized for it.
    func navigate(to url: URL) {
        folder = url
        follow(url)
        let items = Self.contents(of: url, sort: stack.sortOrder)
        grid?.show(items, title: FileManager.default.displayName(atPath: url.path), canGoBack: url.standardizedFileURL.path != root.standardizedFileURL.path)
    }

    func goBack() {
        guard folder.standardizedFileURL.path != root.standardizedFileURL.path else { return }
        let from = folder
        navigate(to: folder.deletingLastPathComponent())
        grid?.select(from)
    }

    // MARK: Showing and closing

    private func present() {
        anchor.tile.map(DockTileArrow.show)
        makeKeyAndOrderFront(nil)
        if let grid { grid.animate(opening: true, towards: tilePoint(in: grid)) }
        makeFirstResponder(contentView is StackGridView ? grid?.document : contentView)
        // A click anywhere else (another app, the Dock, the desktop) closes it
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            MainActor.assumeIsolated {
                guard let current = DockStackPanel.current, !current.dragging else { return }
                DockStackPanel.lastClosed = (current.stack.id, Date())
                current.dismiss()
            }
        }
        let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated {
                if let current = DockStackPanel.current, event.window !== current {
                    current.dismiss()
                }
            }
            return event
        }
        monitors = [outside, inside].compactMap { $0 }
        let winex = Bundle.main.bundleIdentifier ?? "dev.winex.WinEx"
        observers.add(NSWorkspace.didActivateApplicationNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            guard let self, !self.dragging, let app = NSWorkspace.shared.frontmostApplication,
                  !(app.bundleIdentifier ?? "").hasPrefix(winex) else { return }
            self.dismiss()
        }
    }

    private func follow(_ url: URL) {
        followed.map(CloudProgress.shared.unfollow)
        CloudProgress.shared.follow(url)
        followed = url
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.removeAll()
        followed.map(CloudProgress.shared.unfollow)
        followed = nil
        if Self.current === self { Self.current = nil; DockTileArrow.hide() }
        // Back into the tile: the fan's rows, the grid shrinking towards it
        if let fan = contentView as? StackFanView, alphaValue > 0 {
            fan.close { [weak self] in self?.orderOut(nil) }
        } else if let grid, alphaValue > 0 {
            grid.animate(opening: false, towards: tilePoint(in: grid)) { [weak self] in self?.orderOut(nil) }
        } else {
            orderOut(nil)
        }
    }

    /// The tile's point in a view of the panel (where the grid grows from).
    private func tilePoint(in view: NSView) -> NSPoint {
        let local = NSPoint(x: anchor.point.x - frame.minX, y: anchor.point.y - frame.minY)
        switch anchor.edge {
        case .bottom: return NSPoint(x: min(max(local.x, 0), view.bounds.width), y: 0)
        case .left: return NSPoint(x: 0, y: min(max(local.y, 0), view.bounds.height))
        case .right: return NSPoint(x: view.bounds.width, y: min(max(local.y, 0), view.bounds.height))
        }
    }

    // MARK: What a click does

    /// An item opened: a folder in a WinEx window, a file in its app; the stack closes.
    func open(_ entry: StackEntry) {
        guard let item = entry.item else { return openInWinEx() }
        dismiss()
        AppDelegate.shared.open(item.url)
    }

    func openInWinEx() {
        dismiss()
        AppDelegate.shared.showOrOpenWindow(at: folder)
    }

    func reveal(_ url: URL) {
        dismiss()
        AppDelegate.shared.reveal(url)
    }

    /// Dragging an item out: the stack gets out of the way, and closes when it's dropped.
    func beginDrag(_ url: URL, image: NSImage, frame: NSRect, event: NSEvent, from view: NSView & NSDraggingSource) {
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(frame, contents: image)
        view.beginDraggingSession(with: [item], event: event, source: view)
        alphaValue = 0
        ignoresMouseEvents = true
    }

    func dragEnded() {
        dragging = false
        dismiss()
    }

    /// The right-click menu: an item's (open, show in its folder) or the stack's options.
    func menu(for entry: StackEntry?) -> NSMenu {
        guard let item = entry?.item else { return StackOptions.menu(for: stack, panel: self) }
        let menu = NSMenu()
        let target = StackOptions.shared
        let open = menu.addItem(withTitle: L("Открыть"), action: #selector(StackOptions.openItem(_:)), keyEquivalent: "")
        open.target = target
        open.representedObject = item.url
        let reveal = menu.addItem(withTitle: L("Показать в WinEx"), action: #selector(StackOptions.revealItem(_:)), keyEquivalent: "")
        reveal.target = target
        reveal.representedObject = item.url
        menu.addItem(.separator())
        let options = NSMenuItem(title: L("Параметры стопки"), action: nil, keyEquivalent: "")
        options.submenu = StackOptions.menu(for: stack, panel: self)
        menu.addItem(options)
        return menu
    }

    // MARK: Pictures

    private var thumbnails: [String: NSImage] = [:]
    private var requested = Set<String>()

    /// The item's picture: a preview of a document (as the Dock shows), an icon otherwise; drawn
    /// again when the preview arrives.
    func image(for item: FileItem, side: CGFloat, redraw: @escaping () -> Void) -> NSImage {
        guard !item.isFolder, item.url.pathExtension != "app", !AliasIcon.isContainer(item) else { return item.icon }
        let key = "\(Int(side))|\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.url.path)"
        if let cached = thumbnails[key] { return cached }
        if !requested.contains(key) {
            requested.insert(key)
            let request = QLThumbnailGenerator.Request(fileAt: AliasIcon.previewSource(item), size: CGSize(width: side, height: side),
                                                       scale: backingScaleFactor, representationTypes: .thumbnail)
            request.iconMode = true
            let isAlias = item.aliasTarget != nil
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let image = representation?.nsImage else { return }
                DispatchQueue.main.async {
                    self?.thumbnails[key] = isAlias ? AliasIcon.badged(image) : image
                    redraw()
                }
            }
        }
        return item.icon
    }

    /// The round «Открыть в WinEx» button's picture.
    static func openButton(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            NSColor(white: 0.18, alpha: 0.82).setFill()
            circle.fill()
            NSColor(white: 1, alpha: 0.45).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            if let arrow = NSImage(systemSymbolName: "arrowshape.turn.up.right.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: side * 0.34, weight: .semibold)) {
                let size = arrow.size
                let tinted = NSImage(size: size, flipped: false) { r in
                    arrow.draw(in: r)
                    NSColor.white.withAlphaComponent(0.62).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }

    /// A download's or iCloud's bar on an item's picture.
    static func drawProgress(for url: URL, picture: NSRect, side: CGFloat, flipped: Bool) {
        guard let fraction = CloudProgress.shared.fraction(for: url) else { return }
        CloudProgressBar.draw(fraction, in: CloudProgressBar.frame(onPicture: picture, iconSide: side, flipped: flipped))
    }
}

// MARK: - Fan

/// The Dock's fan: the items rise from the tile in a curve bending right, each tilted a little
/// more, the picture on the right and the name on a dark pill to its left; the first item is
/// nearest the Dock, «Открыть в WinEx» on top.
final class StackFanView: NSView, NSDraggingSource {
    static let rowHeight: CGFloat = 68
    static let iconSide: CGFloat = 60
    private static let pillHeight: CGFloat = 32
    /// The curve's radius: the top row of a dozen tilted about 13°, as the Dock's.
    private static let radius: CGFloat = rowHeight * 52
    /// Finder's: plain, a little larger than a menu's.
    private static let font = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let maxPill: CGFloat = 340

    weak var panel: DockStackPanel?
    let entries: [StackEntry]
    /// Where the window goes (screen coordinates).
    let screenFrame: NSRect
    /// Each row's picture centre (view coordinates), tilt (radians, clockwise) and pill width.
    private var centers: [NSPoint] = []
    private var angles: [CGFloat] = []
    private var pillWidths: [CGFloat] = []
    private var tile: NSPoint = .zero
    /// Chosen with the arrow keys (the mouse doesn't light rows up, as in the Dock).
    private var selected: Int? { didSet { if selected != oldValue { needsDisplay = true } } }
    private var pressed: Int?
    private var pressPoint: NSPoint = .zero
    private var openButton = DockStackPanel.openButton(side: 72)
    private let observers = Observers()
    /// How far out the fan is (0: in the tile, 1: open), animated from `from` to `to`.
    private var phase: CGFloat = 0
    private var animation: (from: CGFloat, to: CGFloat, start: Date, length: TimeInterval, done: (() -> Void)?)?
    private var timer: Timer?

    /// Row `i`'s picture centre and tilt on the screen.
    private static func place(_ i: Int, anchor: StackAnchor) -> (center: NSPoint, angle: CGFloat) {
        let along = 16 + iconSide / 2 + rowHeight * CGFloat(i)
        let angle = along / radius
        return (NSPoint(x: anchor.point.x + radius * (1 - cos(angle)), y: anchor.point.y + radius * sin(angle)), angle)
    }

    /// A row's outline on the screen: the pill and the picture, tilted (its left end rises).
    private static func outline(center: NSPoint, angle: CGFloat, pill: CGFloat) -> NSRect {
        let half = max(iconSide, pillHeight) / 2 + 6
        let local = [NSPoint(x: -iconSide / 2 - 10 - pill - 6, y: -half), NSPoint(x: iconSide / 2 + 6, y: -half),
                     NSPoint(x: -iconSide / 2 - 10 - pill - 6, y: half), NSPoint(x: iconSide / 2 + 6, y: half)]
        let points = local.map { p in
            NSPoint(x: center.x + p.x * cos(angle) + p.y * sin(angle), y: center.y - p.x * sin(angle) + p.y * cos(angle))
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return NSRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// The highest point of a fan of `rows` rows (the widest pills), for how many fit.
    static func top(rows: Int, anchor: StackAnchor) -> CGFloat {
        let last = place(rows - 1, anchor: anchor)
        return outline(center: last.center, angle: last.angle, pill: maxPill).maxY
    }

    init(entries: [StackEntry], anchor: StackAnchor) {
        self.entries = entries
        // The rows on the screen first, then the window around them
        var centers: [NSPoint] = [], angles: [CGFloat] = [], widths: [CGFloat] = []
        var bounds = NSRect(x: anchor.point.x - Self.iconSide, y: anchor.point.y - 4, width: 2 * Self.iconSide, height: 8)
        for (i, entry) in entries.enumerated() {
            let (center, angle) = Self.place(i, anchor: anchor)
            let room = center.x - anchor.frame.minX - Self.iconSide / 2 - 30
            let text = (entry.title as NSString).size(withAttributes: [.font: Self.font]).width
            let width = max(44, min(ceil(text) + 34, Self.maxPill, room))
            centers.append(center)
            angles.append(angle)
            widths.append(width)
            bounds = bounds.union(Self.outline(center: center, angle: angle, pill: width))
        }
        // By the screen's right edge: the whole fan moves left to stay on it
        let overflow = bounds.maxX + 4 - anchor.frame.maxX
        if overflow > 0 {
            centers = centers.map { NSPoint(x: $0.x - overflow, y: $0.y) }
            bounds.origin.x -= overflow
        }
        screenFrame = bounds.insetBy(dx: -8, dy: -8).intersection(anchor.frame).integral
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
        let shift = { (p: NSPoint) in NSPoint(x: p.x - self.screenFrame.minX, y: p.y - self.screenFrame.minY) }
        self.centers = centers.map(shift)
        self.angles = angles
        pillWidths = widths
        tile = shift(anchor.point)
        observers.add(CloudProgress.changed) { [weak self] in self?.needsDisplay = true }
        // All the rows at once, growing and showing as they rise out of the tile
        animate(to: 1, length: 0.3)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func animate(to target: CGFloat, length: TimeInterval, done: (() -> Void)? = nil) {
        animation = (phase, target, Date(), length, done)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard let animation else { return stop() }
        let t = min(CGFloat(Date().timeIntervalSince(animation.start) / animation.length), 1)
        // Out: quick then settling (ease-out); in: the reverse (ease-in)
        let eased = animation.to > animation.from ? 1 - pow(1 - t, 3) : t * t * t
        phase = animation.from + (animation.to - animation.from) * eased
        needsDisplay = true
        if t >= 1 {
            self.animation = nil
            stop()
            animation.done?()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Back into the tile, then `done`.
    func close(_ done: @escaping () -> Void) {
        animate(to: 0, length: 0.2, done: done)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    #if DEBUG
    /// For scenarios: drawn as it ends up (or at a moment of opening).
    func debugFinish(at value: CGFloat = 1) { animation = nil; stop(); phase = value; needsDisplay = true }
    #endif

    /// Row `i` at `p` (0: in the tile, small and clear; 1: in its place): it starts a third of
    /// the way out, so everything is there at once and grows into place.
    private func transform(_ i: Int, progress p: CGFloat = 1) -> NSAffineTransform {
        let travel = 0.35 + 0.65 * p
        let center = NSPoint(x: tile.x + (centers[i].x - tile.x) * travel, y: tile.y + (centers[i].y - tile.y) * travel)
        let t = NSAffineTransform()
        t.translateX(by: center.x, yBy: center.y)
        t.rotate(byRadians: -angles[i] * travel)
        let scale = 0.3 + 0.7 * p
        t.scale(by: scale)
        return t
    }

    private func pillRect(_ i: Int) -> NSRect {
        NSRect(x: -Self.iconSide / 2 - 10 - pillWidths[i], y: -Self.pillHeight / 2, width: pillWidths[i], height: Self.pillHeight)
    }

    private func iconRect() -> NSRect {
        NSRect(x: -Self.iconSide / 2, y: -Self.iconSide / 2, width: Self.iconSide, height: Self.iconSide)
    }

    private func row(at point: NSPoint) -> Int? {
        for i in entries.indices.reversed() {
            let inverse = NSAffineTransform(transform: transform(i) as AffineTransform)
            inverse.invert()
            let local = inverse.transform(point)
            let area = NSRect(x: pillRect(i).minX, y: -Self.rowHeight / 2, width: pillWidths[i] + 10 + Self.iconSide, height: Self.rowHeight)
            if area.contains(local) { return i }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        for i in entries.indices {
            let p = phase
            guard p > 0.001 else { continue }
            NSGraphicsContext.saveGraphicsState()
            transform(i, progress: p).concat()
            let alpha = min(1, p * 1.4)
            // The name's pill
            let pill = pillRect(i)
            let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            // Finder's pill: dark glass, a light rim
            (selected == i ? NSColor.controlAccentColor : NSColor(white: 0.2, alpha: 1)).withAlphaComponent(alpha * (selected == i ? 1 : 0.72)).setFill()
            shape.fill()
            NSColor(white: 1, alpha: 0.3 * alpha).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            let textHeight = ceil(Self.font.ascender - Self.font.descender)
            (entries[i].title as NSString).draw(in: NSRect(x: pill.minX + 16, y: pill.midY - textHeight / 2 - 1, width: pill.width - 32, height: textHeight),
                                                withAttributes: attributes)
            // The picture, with a soft shadow
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35 * alpha)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            let image: NSImage
            if let item = entries[i].item {
                image = panel?.image(for: item, side: Self.iconSide) { [weak self] in self?.needsDisplay = true } ?? item.icon
            } else {
                image = openButton
            }
            // (The round button is bigger than the pictures, as Finder's)
            let drawn = DesktopView.aspectFit(image.size, in: entries[i].item == nil ? iconRect().insetBy(dx: 1, dy: 1) : iconRect())
            image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: alpha)
            NSShadow().set()
            if let url = entries[i].item?.url {
                DockStackPanel.drawProgress(for: url, picture: drawn, side: Self.iconSide, flipped: false)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Mouse and keys


    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        pressed = row(at: pressPoint)
        if pressed == nil { panel?.dismiss() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, let item = entries[pressed].item, hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 4 else { return }
        self.pressed = nil
        let image = panel?.image(for: item, side: Self.iconSide) {} ?? item.icon
        let center = transform(pressed).transform(NSPoint.zero)
        let frame = NSRect(x: center.x - Self.iconSide / 2, y: center.y - Self.iconSide / 2, width: Self.iconSide, height: Self.iconSide)
        panel?.beginDrag(item.url, image: image, frame: frame, event: event, from: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed, row(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        self.pressed = nil
        panel?.open(entries[pressed])
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let panel else { return }
        let i = row(at: convert(event.locationInWindow, from: nil))
        NSMenu.popUpContextMenu(panel.menu(for: i.map { entries[$0] }), with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: selected = min((selected ?? -1) + 1, entries.count - 1)   // ↑: away from the Dock
        case 125: selected = max((selected ?? entries.count) - 1, 0)        // ↓
        case 36, 76: if let selected { panel?.open(entries[selected]) }
        case 53: panel?.dismiss()
        default: super.keyDown(with: event)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DockStacks.dragEnded(session, at: screenPoint, operation: operation)
        panel?.dragEnded()
    }
}

// MARK: - Grid

/// The Dock's grid: a rounded translucent panel with the folder's name on top, its items in rows
/// (scrolling when they don't fit), «Открыть в WinEx» last; a folder opens inside it, with a back
/// arrow by the name.
final class StackGridView: NSVisualEffectView {
    static let cell = NSSize(width: 116, height: 98)
    static let iconSide: CGFloat = 60
    static let padding: CGFloat = 14
    static let header: CGFloat = 42

    weak var panel: DockStackPanel?
    let document = StackGridDocument()
    private let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "")
    private let back = NSButton()

    init(panel: DockStackPanel) {
        self.panel = panel
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Назад"))
        back.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        back.contentTintColor = .white
        back.isBordered = false
        back.target = self
        back.action = #selector(goBack)
        back.toolTip = L("Назад")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        document.grid = self
        [title, back, scroll].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func goBack() { panel?.goBack() }

    /// Grows out of the tile (`point`, in this view) as it shows, or shrinks back into it and
    /// fades as it closes.
    func animate(opening: Bool, towards point: NSPoint, done: (() -> Void)? = nil) {
        guard let layer else { done?(); return }
        // (A layer-backed view's layer scales about its corner: moved to the point and back)
        var small = CATransform3DMakeTranslation(point.x, point.y, 0)
        small = CATransform3DScale(small, 0.35, 0.35, 1)
        small = CATransform3DTranslate(small, -point.x, -point.y, 0)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = opening ? small : CATransform3DIdentity
        scale.toValue = opening ? CATransform3DIdentity : small
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opening ? 0 : 1
        fade.toValue = opening ? 1 : 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = opening ? 0.3 : 0.2
        group.timingFunction = CAMediaTimingFunction(controlPoints: opening ? 0.2 : 0.5, opening ? 0.9 : 0, opening ? 0.3 : 0.8, opening ? 1 : 0.4)
        if !opening {
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done?() } }
        layer.add(group, forKey: "stack")
        CATransaction.commit()
    }

    func select(_ url: URL) { document.select(url) }

    /// A folder's items: the grid sized for them (columns as square as fits, rows up to the room
    /// above the Dock) and the panel fitted to it.
    func show(_ items: [FileItem], title: String, canGoBack: Bool) {
        guard let panel else { return }
        let entries = items.map { StackEntry(item: $0) } + [StackEntry(item: nil)]
        let room = panel.anchor.room
        let maxColumns = max(1, Int((room.width - 40 - 2 * Self.padding) / Self.cell.width))
        let columns = max(1, min(7, maxColumns, Int(ceil(sqrt(Double(entries.count) * 1.4)))))
        let rows = Int(ceil(Double(entries.count) / Double(columns)))
        let fitRows = max(1, Int((room.height - 24 - Self.header - 2 * Self.padding) / Self.cell.height))
        let shownRows = min(rows, fitRows)
        let size = NSSize(width: CGFloat(columns) * Self.cell.width + 2 * Self.padding,
                          height: Self.header + CGFloat(shownRows) * Self.cell.height + Self.padding)
        self.title.stringValue = title
        back.isHidden = !canGoBack
        panel.placeGrid(size)
        frame = NSRect(origin: .zero, size: size)
        self.title.frame = NSRect(x: 40, y: size.height - Self.header + 8, width: size.width - 80, height: 22)
        back.frame = NSRect(x: 10, y: size.height - Self.header + 6, width: 28, height: 26)
        scroll.frame = NSRect(x: Self.padding, y: Self.padding / 2, width: size.width - 2 * Self.padding, height: size.height - Self.header - Self.padding / 2)
        document.show(entries, columns: columns, width: scroll.frame.width)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

final class StackGridDocument: NSView, NSDraggingSource {
    weak var grid: StackGridView?
    private var panel: DockStackPanel? { grid?.panel }
    private(set) var entries: [StackEntry] = []
    private var columns = 1
    /// Chosen with the keys.
    private var selected: Int? { didSet { if selected != oldValue { needsDisplay = true; selected.map(scrollToItem) } } }
    private var pressed: Int?
    private var pressPoint: NSPoint = .zero
    private var pendingSelection: URL?
    private let openButton = DockStackPanel.openButton(side: 52)
    private let observers = Observers()

    override init(frame: NSRect) {
        super.init(frame: frame)
        observers.add(CloudProgress.changed) { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ entries: [StackEntry], columns: Int, width: CGFloat) {
        self.entries = entries
        self.columns = columns
        selected = nil
        let rows = Int(ceil(Double(entries.count) / Double(columns)))
        setFrameSize(NSSize(width: width, height: CGFloat(rows) * StackGridView.cell.height))
        if let pendingSelection {
            selected = entries.firstIndex { $0.item?.url.standardizedFileURL == pendingSelection.standardizedFileURL }
            self.pendingSelection = nil
        }
        needsDisplay = true
    }

    func select(_ url: URL) {
        selected = entries.firstIndex { $0.item?.url.standardizedFileURL == url.standardizedFileURL }
    }

    private func cellRect(_ i: Int) -> NSRect {
        let cell = StackGridView.cell
        let x = (bounds.width - CGFloat(columns) * cell.width) / 2
        return NSRect(x: x + CGFloat(i % columns) * cell.width, y: CGFloat(i / columns) * cell.height, width: cell.width, height: cell.height)
    }

    private func iconRect(_ i: Int) -> NSRect {
        let cell = cellRect(i), side = StackGridView.iconSide
        return NSRect(x: cell.midX - side / 2, y: cell.minY + 8, width: side, height: side)
    }

    private func index(at point: NSPoint) -> Int? {
        entries.indices.first { cellRect($0).insetBy(dx: 3, dy: 2).contains(point) }
    }

    private func scrollToItem(_ i: Int) { scrollToVisible(cellRect(i)) }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
                                                         .paragraphStyle: paragraph, .shadow: shadow]
        for i in entries.indices where cellRect(i).intersects(dirtyRect) {
            let cell = cellRect(i)
            if selected == i {
                NSColor(white: 1, alpha: 0.22).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 4, dy: 2), xRadius: 10, yRadius: 10).fill()
            }
            let image: NSImage
            if let item = entries[i].item {
                image = panel?.image(for: item, side: StackGridView.iconSide) { [weak self] in self?.needsDisplay = true } ?? item.icon
            } else {
                image = openButton
            }
            let box = entries[i].item == nil ? iconRect(i).insetBy(dx: 4, dy: 4) : iconRect(i)
            let drawn = DesktopView.aspectFit(image.size, in: box)
            image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if let url = entries[i].item?.url {
                DockStackPanel.drawProgress(for: url, picture: drawn, side: StackGridView.iconSide, flipped: true)
            }
            (entries[i].title as NSString).draw(in: NSRect(x: cell.minX + 6, y: cell.minY + 8 + StackGridView.iconSide + 6, width: cell.width - 12, height: 17),
                                                withAttributes: attributes)
        }
    }

    // MARK: Mouse and keys


    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        pressed = index(at: pressPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, let item = entries[pressed].item, hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 4 else { return }
        self.pressed = nil
        let image = panel?.image(for: item, side: StackGridView.iconSide) {} ?? item.icon
        panel?.beginDrag(item.url, image: image, frame: DesktopView.aspectFit(image.size, in: iconRect(pressed)), event: event, from: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed, index(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        self.pressed = nil
        activate(pressed, inWindow: event.modifierFlags.contains(.command))
    }

    /// A folder opens inside the grid (⌘: in a WinEx window); anything else as from the fan.
    private func activate(_ i: Int, inWindow: Bool = false) {
        let entry = entries[i]
        if let item = entry.item, item.isFolder, item.aliasTarget == nil, !inWindow {
            panel?.navigate(to: item.url)
        } else {
            panel?.open(entry)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let panel else { return }
        let i = index(at: convert(event.locationInWindow, from: nil))
        NSMenu.popUpContextMenu(panel.menu(for: i.map { entries[$0] }), with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        let last = entries.count - 1
        let current = selected
        switch event.keyCode {
        case 123: selected = max((current ?? 1) - 1, 0)
        case 124: selected = min((current ?? -1) + 1, last)
        case 126:
            if event.modifierFlags.contains(.command) { panel?.goBack(); return }
            selected = max((current ?? columns) - columns, 0)
        case 125:
            if event.modifierFlags.contains(.command), let current { activate(current); return }
            selected = min((current ?? -columns) + columns, last)
        case 36, 76: if let current { activate(current) }
        case 51: panel?.goBack()
        case 53: panel?.dismiss()
        default:
            // Typing a name's first letters goes to it
            guard let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return super.keyDown(with: event) }
            if let match = entries.firstIndex(where: { $0.item?.name.lowercased().hasPrefix(typed) == true }) { selected = match }
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DockStacks.dragEnded(session, at: screenPoint, operation: operation)
        panel?.dragEnded()
    }
}

// MARK: - List

/// The Dock's list: a menu by the tile with every item (a folder's items in its submenu), then
/// «Открыть в WinEx» and the stack's options.
@MainActor
enum StackList {
    static func popUp(_ stack: DockStack, folder: URL, items: [FileItem], anchor: StackAnchor) {
        let menu = NSMenu()
        fill(menu, items: items)
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: L("Открыть в WinEx"), action: #selector(StackOptions.revealFolder(_:)), keyEquivalent: "")
        open.target = StackOptions.shared
        open.representedObject = folder
        let options = NSMenuItem(title: L("Параметры стопки"), action: nil, keyEquivalent: "")
        options.submenu = StackOptions.menu(for: stack, panel: nil)
        menu.addItem(options)
        let size = menu.size
        var point: NSPoint
        switch anchor.edge {
        case .bottom: point = NSPoint(x: anchor.point.x - 20, y: anchor.point.y + size.height + 6)
        case .left: point = NSPoint(x: anchor.point.x + 6, y: anchor.point.y + size.height / 2)
        case .right: point = NSPoint(x: anchor.point.x - size.width - 6, y: anchor.point.y + size.height / 2)
        }
        point.x = min(max(point.x, anchor.frame.minX + 4), anchor.frame.maxX - size.width - 4)
        anchor.tile.map(DockTileArrow.show)
        menu.popUp(positioning: nil, at: point, in: nil)
        DockTileArrow.hide()
    }

    /// One row per item (16-point icons, as the Dock's list); folders with their items inside.
    static func fill(_ menu: NSMenu, items: [FileItem]) {
        if items.isEmpty {
            menu.addItem(withTitle: L("Нет объектов"), action: nil, keyEquivalent: "").isEnabled = false
        }
        for item in items.prefix(500) {
            let row = NSMenuItem(title: item.name, action: #selector(StackOptions.openItem(_:)), keyEquivalent: "")
            row.target = StackOptions.shared
            row.representedObject = item.url
            let icon = item.icon.copy() as? NSImage ?? item.icon
            icon.size = NSSize(width: 16, height: 16)
            row.image = icon
            if item.isFolder, item.aliasTarget == nil {
                let submenu = NSMenu(title: item.url.path)
                submenu.delegate = StackOptions.shared
                // (Filled when it opens)
                submenu.addItem(withTitle: "…", action: nil, keyEquivalent: "")
                row.submenu = submenu
            }
            menu.addItem(row)
        }
    }
}

// MARK: - Options

/// The stack's options (sort, view, open, take out of the Dock) and the actions of its menus.
@MainActor
final class StackOptions: NSObject, NSMenuDelegate {
    static let shared = StackOptions()

    static func menu(for stack: DockStack, panel: DockStackPanel?) -> NSMenu {
        let menu = NSMenu()
        let target = shared
        let sort = NSMenuItem(title: L("Сортировать по"), action: nil, keyEquivalent: "")
        sort.submenu = NSMenu()
        for option in DockStack.Sort.allCases {
            let item = sort.submenu?.addItem(withTitle: DockStack.title(option), action: #selector(setSort(_:)), keyEquivalent: "")
            item?.target = target
            item?.representedObject = [stack.id, option.rawValue]
            item?.state = stack.sort == option ? .on : .off
        }
        menu.addItem(sort)
        let display = NSMenuItem(title: L("Показывать как"), action: nil, keyEquivalent: "")
        display.submenu = NSMenu()
        for (option, title) in [(DockStack.Display.folder, L("Папку")), (.stack, L("Стопку"))] {
            let item = display.submenu?.addItem(withTitle: title, action: #selector(setDisplay(_:)), keyEquivalent: "")
            item?.target = target
            item?.representedObject = [stack.id, option.rawValue]
            item?.state = (stack.display ?? .stack) == option ? .on : .off
        }
        menu.addItem(display)
        let view = NSMenuItem(title: L("Просмотр содержимого"), action: nil, keyEquivalent: "")
        view.submenu = NSMenu()
        for option in DockStack.View.allCases {
            let item = view.submenu?.addItem(withTitle: DockStack.title(option), action: #selector(setView(_:)), keyEquivalent: "")
            item?.target = target
            item?.representedObject = [stack.id, option.rawValue]
            item?.state = stack.view == option ? .on : .off
        }
        menu.addItem(view)
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: L("Открыть в WinEx"), action: #selector(revealFolder(_:)), keyEquivalent: "")
        open.target = target
        open.representedObject = panel?.folder ?? DockStacks.folder(of: stack) ?? stack.folder
        let remove = menu.addItem(withTitle: L("Убрать из Dock"), action: #selector(removeStack(_:)), keyEquivalent: "")
        remove.target = target
        remove.representedObject = stack.id
        return menu
    }

    @objc func setSort(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, var stack = DockStacks.stack(id: pair[0]),
              let sort = DockStack.Sort(rawValue: pair[1]) else { return }
        stack.sort = sort
        DockStacks.update(stack)
        DockStacks.refreshIcon(stack)
        reopen(stack)
    }

    @objc func setDisplay(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, var stack = DockStacks.stack(id: pair[0]),
              let display = DockStack.Display(rawValue: pair[1]) else { return }
        stack.display = display
        DockStacks.update(stack)
        DockStacks.refreshIcon(stack)
    }

    @objc func setView(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, var stack = DockStacks.stack(id: pair[0]),
              let view = DockStack.View(rawValue: pair[1]) else { return }
        stack.view = view
        DockStacks.update(stack)
        reopen(stack)
    }

    /// The open stack shown again as it's set now.
    private func reopen(_ stack: DockStack) {
        guard let panel = DockStackPanel.current, panel.stack.id == stack.id else { return }
        let anchor = panel.anchor, root = panel.root
        panel.dismiss()
        DockStackPanel.show(stack, folder: root, anchor: anchor)
    }

    @objc func revealFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        DockStackPanel.current?.dismiss()
        AppDelegate.shared.showOrOpenWindow(at: url)
    }

    @objc func openItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        DockStackPanel.current?.dismiss()
        AppDelegate.shared.open(url)
    }

    @objc func revealItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        DockStackPanel.current?.dismiss()
        AppDelegate.shared.reveal(url)
    }

    @objc func removeStack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let stack = DockStacks.stack(id: id) else { return }
        DockStackPanel.current?.dismiss()
        DockStacks.remove(stack)
    }

    /// A folder's submenu in the list, filled when it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.first?.title == "…" else { return }
        menu.removeAllItems()
        let folder = URL(fileURLWithPath: menu.title)
        StackList.fill(menu, items: DockStackPanel.contents(of: folder, sort: FileItem.SortOrder(key: "name", ascending: true)))
    }
}

/// The stack's tile while it's open, as the Dock draws its own: a dark rounded square with an
/// arrow pointing down, over the tile (clicks go through to it: a click there closes the stack).
@MainActor
enum DockTileArrow {
    private static var window: NSPanel?

    static func show(over tile: NSRect) {
        hide(animated: false)
        let side = min(tile.width, tile.height) * 0.86
        let frame = NSRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side).integral
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSImageView(image: picture(side: frame.width))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        window = panel
    }

    static func hide(animated: Bool = true) {
        guard let panel = window else { return }
        window = nil
        guard animated else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }

    static func picture(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let square = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: side * 0.24, yRadius: side * 0.24)
            NSColor(white: 0.26, alpha: 1).setFill()
            square.fill()
            NSColor(white: 1, alpha: 0.12).setStroke()
            square.lineWidth = 1
            square.stroke()
            if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: side * 0.36, weight: .semibold)) {
                let size = chevron.size
                let white = NSImage(size: size, flipped: false) { r in
                    chevron.draw(in: r)
                    NSColor.white.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                white.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }
}
