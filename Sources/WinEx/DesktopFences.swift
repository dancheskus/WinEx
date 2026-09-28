import AppKit

/// A fence on the WinEx desktop (like Stardock Fences): a titled, translucent area its icons live
/// in. Moved by its title, resized by its edges — both snap to the monitor's edges, the other
/// fences and each other's edges; double-click on the title rolls it up.
struct DesktopFence: Codable, Equatable {
    var id = UUID().uuidString
    var title: String
    /// The monitor (display UUID) and the frame in points from its top-left corner.
    var screenID: String
    var x: Double, y: Double, width: Double, height: Double
    /// Desktop names of its icons, in order.
    var members: [String] = []
    var collapsed = false
    /// A folder portal: shows this folder's contents instead of desktop icons.
    var portalPath: String?
    /// Its own tint (hex "#RRGGBB"); nil — the one from Settings ▸ Ограды.
    var color: String?

    var isPortal: Bool { portalPath != nil }

    var frame: NSRect {
        get { NSRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }

    static let titleHeight: CGFloat = 30
    static let padding: CGFloat = 8
}

/// Settings ▸ Ограды: how every fence looks and behaves.
enum FenceStyle {
    static let didChange = Notification.Name("WinExFenceStyleChanged")
    private static var defaults: UserDefaults { AppDefaults.store }

    static var cornerRadius: CGFloat {
        get { CGFloat(defaults.object(forKey: "fenceRadius") as? Double ?? 12) }
        set { defaults.set(Double(newValue), forKey: "fenceRadius"); changed() }
    }

    /// The tint (hex); the panel is this colour at `opacity`.
    static var color: String {
        get { defaults.string(forKey: "fenceColor") ?? "#000000" }
        set { defaults.set(newValue, forKey: "fenceColor"); changed() }
    }

    static var opacity: CGFloat {
        get { CGFloat(defaults.object(forKey: "fenceOpacity") as? Double ?? 0.22) }
        set { defaults.set(Double(newValue), forKey: "fenceOpacity"); changed() }
    }

    /// Frosted glass behind the panel (the wallpaper blurred).
    static var blur: Bool {
        get { defaults.object(forKey: "fenceBlur") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fenceBlur"); changed() }
    }

    /// Zones on the desktop at all (off: every icon is a plain desktop icon again; the zones are
    /// kept and come back when switched on).
    static var enabled: Bool {
        get { defaults.object(forKey: "fencesEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fencesEnabled"); changed() }
    }

    static var snapping: Bool {
        get { defaults.object(forKey: "fenceSnapping") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fenceSnapping"); changed() }
    }

    /// A double-click on the desktop hides (and shows again) every icon and fence.
    static var quickHide: Bool {
        get { defaults.object(forKey: "fenceQuickHide") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fenceQuickHide"); changed() }
    }

    private static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }

    static let presets = ["#000000", "#1C3D6E", "#27496D", "#2E5E4E", "#5B3A70", "#7A2E3A", "#6B4E16", "#4A4A4A", "#FFFFFF"]

    static func nsColor(_ hex: String?) -> NSColor? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#"), text.count == 7 else { return nil }
        text.removeFirst()
        guard let value = UInt32(text, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// Magnetic edges: a moved or resized rectangle clings to the lines near it.
enum FenceSnap {
    struct Guide: Equatable {
        /// Vertical (a line at x) or horizontal (at y), from…to along the line.
        var vertical: Bool
        var position: CGFloat
        var from: CGFloat, to: CGFloat
    }

    static let threshold: CGFloat = 12
    static let gap: CGFloat = 8

    /// The default gap plus the gaps between neighbouring rects (side by side or one above the
    /// other), up to 120 pt — offered along both axes.
    static func gaps(between rects: [NSRect]) -> (horizontal: [CGFloat], vertical: [CGFloat]) {
        var horizontal: Set<CGFloat> = [gap], vertical: Set<CGFloat> = [gap]
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let dx = max(b.minX - a.maxX, a.minX - b.maxX)
                let dy = max(b.minY - a.maxY, a.minY - b.maxY)
                if overlapY > 0, dx > 0, dx <= 120 { horizontal.insert(dx.rounded()) }
                if overlapX > 0, dy > 0, dy <= 120 { vertical.insert(dy.rounded()) }
            }
        }
        // One rhythm for the whole desktop: a spacing used side by side works one above the other too
        let all = horizontal.union(vertical).sorted()
        return (all, all)
    }

    /// `rect` with its moving edges pulled onto the nearest target lines (within the threshold).
    /// `edges`: which sides move (all four when the whole rect moves). Targets: the area's edges,
    /// the other rects' edges (lined up with them, or `gap` away from them side by side).
    static func snap(_ rect: NSRect, edges: Set<NSRectEdge>, area: NSRect, others: [NSRect]) -> (NSRect, [Guide]) {
        let moving = edges.count == 4
        // The spacing already used between the other fences is offered too, so a new fence can
        // keep the same rhythm
        let (xGaps, yGaps) = gaps(between: others)
        var xs: [CGFloat] = [area.minX + gap, area.maxX - gap]
        var ys: [CGFloat] = [area.minY + gap, area.maxY - gap]
        for other in others {
            xs += [other.minX, other.maxX]
            ys += [other.minY, other.maxY]
            for g in xGaps { xs += [other.maxX + g, other.minX - g] }
            for g in yGaps { ys += [other.maxY + g, other.minY - g] }
        }
        func nearest(_ value: CGFloat, in lines: [CGFloat]) -> CGFloat? {
            lines.filter { abs($0 - value) <= threshold }.min { abs($0 - value) < abs($1 - value) }
        }
        var result = rect
        var guides: [Guide] = []
        // Horizontal position: left or right edge, whichever is closer to a line
        if moving {
            let left = nearest(rect.minX, in: xs).map { ($0 - rect.minX, $0) }
            let right = nearest(rect.maxX, in: xs).map { ($0 - rect.maxX, $0) }
            if let best = [left, right].compactMap({ $0 }).min(by: { abs($0.0) < abs($1.0) }) {
                result.origin.x += best.0
                guides.append(Guide(vertical: true, position: best.1, from: 0, to: 0))
            }
            let top = nearest(rect.minY, in: ys).map { ($0 - rect.minY, $0) }
            let bottom = nearest(rect.maxY, in: ys).map { ($0 - rect.maxY, $0) }
            if let best = [top, bottom].compactMap({ $0 }).min(by: { abs($0.0) < abs($1.0) }) {
                result.origin.y += best.0
                guides.append(Guide(vertical: false, position: best.1, from: 0, to: 0))
            }
        } else {
            if edges.contains(.minX), let line = nearest(rect.minX, in: xs) {
                result.size.width += result.minX - line
                result.origin.x = line
                guides.append(Guide(vertical: true, position: line, from: 0, to: 0))
            }
            if edges.contains(.maxX), let line = nearest(rect.maxX, in: xs) {
                result.size.width = line - result.minX
                guides.append(Guide(vertical: true, position: line, from: 0, to: 0))
            }
            if edges.contains(.minY), let line = nearest(rect.minY, in: ys) {
                result.size.height += result.minY - line
                result.origin.y = line
                guides.append(Guide(vertical: false, position: line, from: 0, to: 0))
            }
            if edges.contains(.maxY), let line = nearest(rect.maxY, in: ys) {
                result.size.height = line - result.minY
                guides.append(Guide(vertical: false, position: line, from: 0, to: 0))
            }
        }
        // Guides span the snapped rect and whatever it lines up with
        guides = guides.map { guide in
            var g = guide
            let related = others.filter { other in
                guide.vertical ? ([other.minX, other.maxX] + xGaps.flatMap { [other.maxX + $0, other.minX - $0] }).contains(guide.position)
                               : ([other.minY, other.maxY] + yGaps.flatMap { [other.maxY + $0, other.minY - $0] }).contains(guide.position)
            } + [result]
            g.from = related.map { guide.vertical ? $0.minY : $0.minX }.min() ?? 0
            g.to = related.map { guide.vertical ? $0.maxY : $0.maxX }.max() ?? 0
            if !others.contains(where: { related.contains($0) }) {
                // Only the monitor's edge: along the whole side
                g.from = guide.vertical ? area.minY : area.minX
                g.to = guide.vertical ? area.maxY : area.maxX
            }
            return g
        }
        return (result, guides)
    }
}

/// The fence's panel: a frosted, rounded area with its title; the icons are drawn by the desktop
/// on top of it. Its title bar and edges take the mouse; clicks inside go to the desktop.
@MainActor
final class FenceView: NSView, NSTextFieldDelegate {
    var fence: DesktopFence { didSet { if fence != oldValue { redraw(); updateBlur(); window?.invalidateCursorRects(for: self) } } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { redraw() } } }
    /// Its icons scroll: how far, how much there is and how much shows. Driven by a real (empty)
    /// scroll view over the fence's inside, so it scrolls exactly like a portal — the overlay
    /// scroller, momentum, the rubber band at the ends; the icons follow it.
    var scroller: (offset: CGFloat, content: CGFloat, visible: CGFloat)? {
        didSet { syncScrollView() }
    }
    /// The fence was scrolled (the offset can go below 0 or past the end while it bounces).
    var onScroll: ((CGFloat) -> Void)?
    private var scrollView: NSScrollView?
    private var settingScroll = false
    private var lastScrolled = Date.distantPast
    private var extraScroll: CGFloat { max(0, (scroller?.content ?? 0) - (scroller?.visible ?? 0)) }

    private func syncScrollView() {
        guard let scroller, scroller.content > scroller.visible + 0.5, !fence.collapsed else {
            scrollView?.removeFromSuperview()
            scrollView = nil
            return
        }
        let view = scrollView ?? makeScrollView()
        let frame = NSRect(x: 0, y: DesktopFence.titleHeight, width: bounds.width, height: max(0, bounds.height - DesktopFence.titleHeight))
        settingScroll = true
        if view.frame != frame { view.frame = frame }
        let height = frame.height + extraScroll
        if view.documentView?.frame.height != height { view.documentView?.setFrameSize(NSSize(width: frame.width, height: height)) }
        // Moved from outside (resized, icons added): the scroll view follows, unless it's bouncing
        let current = view.contentView.bounds.origin.y
        if current >= 0, current <= extraScroll, abs(current - scroller.offset) > 0.5 {
            view.contentView.scroll(to: NSPoint(x: 0, y: scroller.offset))
            view.reflectScrolledClipView(view.contentView)
        }
        settingScroll = false
    }

    private func makeScrollView() -> NSScrollView {
        let view = NSScrollView()
        view.drawsBackground = false
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.scrollerStyle = .overlay
        view.scrollerKnobStyle = .light
        view.verticalScrollElasticity = .allowed
        view.horizontalScrollElasticity = .none
        let document = FlippedView()
        view.documentView = document
        view.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: view.contentView)
        addSubview(view, positioned: .above, relativeTo: overlay)
        scrollView = view
        return view
    }

    @objc private func scrolled(_ note: Notification) {
        guard !settingScroll, let view = scrollView else { return }
        lastScrolled = Date()
        onScroll?(view.contentView.bounds.origin.y)
    }

    // The mouse over the fence: the scroller shows for a moment, telling there's more to scroll
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.userInfo?["hover"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: ["hover": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["hover"] != nil else { return super.mouseEntered(with: event) }
        // A zone's own scroll view, or a portal's (only when there's something to scroll)
        if let scrollView { scrollView.flashScrollers() }
        if let portalView, let document = portalView.documentView,
           document.frame.height > portalView.contentView.bounds.height + 1 { portalView.flashScrollers() }
    }

    /// The desktop passes on scrolling over the fence's inside.
    func scroll(with event: NSEvent) -> Bool {
        guard let scrollView else { return false }
        scrollView.scrollWheel(with: event)
        return true
    }

    /// Moves the scroll view as a trackpad would (past the top: as while it bounces).
    func debugScroll(to y: CGFloat) {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.flashScrollers()
    }

    var debugScrollState: String {
        guard let scrollView else { return "no scroll view (scroller: \(scroller.map { "\($0)" } ?? "nil"))" }
        return "clip \(scrollView.contentView.bounds), document \(scrollView.documentView?.frame ?? .zero)"
    }

    /// Whether the scroll view is past an end right now (bouncing back).
    var isBouncing: Bool {
        guard let y = scrollView?.contentView.bounds.origin.y else { return false }
        return y < 0 || y > extraScroll
    }

    /// The scroller takes the mouse only just after scrolling, while it shows (the right edge
    /// resizes the fence otherwise).
    fileprivate func scrollerHit(_ local: NSPoint) -> NSView? {
        guard let scrollView, let scroller = scrollView.verticalScroller, Date().timeIntervalSince(lastScrolled) < 1.2 else { return nil }
        let frame = scroller.convert(scroller.bounds, to: self)
        return frame.contains(local) ? scroller : nil
    }

    /// Live frame while moving / resizing (with the snapping guides), then the final one.
    var onFrame: ((NSRect, _ final: Bool) -> Void)?
    /// The part of the monitor a fence may take (it's kept inside while moved or resized).
    var keepInside: (() -> NSRect?)?
    /// Moved with the mouse over another monitor: its frame in screen coordinates (nil: back over
    /// its own); `final` when let go there — true if the fence went over.
    var onOtherMonitor: ((_ screenFrame: NSRect?, _ final: Bool) -> Bool)?
    var snap: ((NSRect, Set<NSRectEdge>) -> (NSRect, [FenceSnap.Guide]))?
    var onGuides: (([FenceSnap.Guide]) -> Void)?
    var onToggleCollapsed: (() -> Void)?
    var onMenu: ((NSEvent) -> NSMenu?)?
    var onRename: ((String) -> Void)?
    var minimumSize = NSSize(width: 140, height: 120)

    private let blur = NSVisualEffectView()
    private let overlay = FenceOverlay()
    private static let edge: CGFloat = 6

    init(fence: DesktopFence) {
        self.fence = fence
        super.init(frame: fence.frame)
        wantsLayer = true
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        addSubview(blur, positioned: .below, relativeTo: nil)
        // Everything the fence draws goes on a layer above the frosted glass (drawn below it, the
        // glass would dim the title)
        overlay.owner = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .above, relativeTo: blur)
        updateBlur()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { overlay.needsDisplay = true } }
    }

    /// Everything is drawn by the overlay, and the desktop window doesn't redraw it by itself:
    /// a change shows at once.
    func redraw() {
        overlay.needsDisplay = true
        overlay.displayIfNeeded()
    }

    private func updateBlur() {
        blur.isHidden = !FenceStyle.blur
        blur.alphaValue = 0.55
        blur.layer?.cornerRadius = FenceStyle.cornerRadius
    }

    /// Settings changed: redraw with the new look.
    func styleChanged() {
        updateBlur()
        redraw()
    }

    private var titleRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: DesktopFence.titleHeight) }

    /// Which edges a point grabs (empty: none). Near a corner — both of its edges.
    private func edges(at point: NSPoint) -> Set<NSRectEdge> {
        var result = Set<NSRectEdge>()
        let e = Self.edge, corner = Self.corner
        let nearLeft = point.x < corner, nearRight = point.x > bounds.width - corner
        let nearTop = point.y < corner, nearBottom = point.y > bounds.height - corner
        if point.x < e || (nearLeft && (nearTop || nearBottom) && !fence.collapsed) { result.insert(.minX) }
        if point.x > bounds.width - e || (nearRight && (nearTop || nearBottom) && !fence.collapsed) { result.insert(.maxX) }
        if !fence.collapsed {
            if point.y < e / 2 || (nearTop && (nearLeft || nearRight)) { result.insert(.minY) }
            if point.y > bounds.height - e || (nearBottom && (nearLeft || nearRight)) { result.insert(.maxY) }
        }
        return result
    }

    private static let corner: CGFloat = 14

    /// The roll-up chevron at the title's left.
    private var chevronRect: NSRect { NSRect(x: 4, y: 0, width: 26, height: DesktopFence.titleHeight) }
    /// A portal navigated into a subfolder: "‹" back to where it came from.
    private var backRect: NSRect? {
        portalView?.canGoUp == true && !fence.collapsed ? NSRect(x: 30, y: 0, width: 24, height: DesktopFence.titleHeight) : nil
    }
    /// A portal: the button opening its (current) folder in WinEx, at the title's right.
    private var openRect: NSRect? {
        fence.isPortal ? NSRect(x: bounds.width - 32, y: 0, width: 26, height: DesktopFence.titleHeight) : nil
    }
    /// What the title says: a portal's current folder (not renamable), otherwise the fence's name.
    private var shownTitle: String { portalView.map { $0.currentFolder.displayName } ?? fence.title }

    /// The title bar and the edges; the inside belongs to the desktop (icons, rubber band, drops)
    /// — or, for a portal, to the portal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, alphaValue > 0.01 else { return nil }  // quick-hidden: not there
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if renameField.map({ $0.frame.contains(local) }) == true { return renameField }
        // The scroller, while it's showing, can be dragged (over the right edge's resizing)
        if let scroller = scrollerHit(local) { return scroller }
        // Scrolling over the inside goes to the fence's scroll view, as in a portal (clicks don't:
        // they're for the icons)
        if NSApp.currentEvent?.type == .scrollWheel, let scrollView, scrollView.frame.contains(local) {
            return scrollView.documentView ?? scrollView
        }
        if titleRect.contains(local) || !edges(at: local).isEmpty { return self }
        if let portalView, !portalView.isHidden, portalView.frame.contains(local) { return portalView.hitTest(local) ?? portalView }
        return nil
    }

    // MARK: Portal

    private(set) var portalView: PortalView?

    /// A portal fence shows its folder inside; an ordinary one — the desktop's icons (drawn by it).
    func configurePortal(cell: NSSize, iconSide: CGFloat) {
        guard let path = fence.portalPath else {
            portalView?.removeFromSuperview()
            portalView = nil
            return
        }
        if portalView?.folder.path != path {
            portalView?.removeFromSuperview()
            let portal = PortalView(folder: URL(fileURLWithPath: path), cell: cell, iconSide: iconSide)
            portal.onNavigate = { [weak self] in
                guard let self else { return }
                self.redraw()  // the title: folder name, back button
                self.window?.invalidateCursorRects(for: self)
            }
            addSubview(portal)
            portalView = portal
        }
        portalView?.update(cell: cell, iconSide: iconSide)
        portalView?.isHidden = fence.collapsed
        needsLayout = true
    }

    override func layout() {
        super.layout()
        portalView?.frame = NSRect(x: DesktopFence.padding / 2, y: DesktopFence.titleHeight,
                                   width: bounds.width - DesktopFence.padding, height: max(0, bounds.height - DesktopFence.titleHeight - DesktopFence.padding / 2))
    }

    override func resetCursorRects() {
        let e = Self.edge, c = Self.corner, w = bounds.width, h = bounds.height
        addCursorRect(chevronRect.insetBy(dx: 0, dy: 4), cursor: .pointingHand)
        if !fence.isPortal { addCursorRect(titleTextHitRect.insetBy(dx: 0, dy: 5), cursor: .iBeam) }
        if let backRect { addCursorRect(backRect.insetBy(dx: 0, dy: 4), cursor: .pointingHand) }
        if let openRect { addCursorRect(openRect.insetBy(dx: 0, dy: 4), cursor: .pointingHand) }
        addCursorRect(NSRect(x: 0, y: c, width: e, height: max(h - 2 * c, 0)), cursor: .frameResize(position: .left, directions: .all))
        addCursorRect(NSRect(x: w - e, y: c, width: e, height: max(h - 2 * c, 0)), cursor: .frameResize(position: .right, directions: .all))
        guard !fence.collapsed else { return }
        addCursorRect(NSRect(x: c, y: h - e, width: max(w - 2 * c, 0), height: e), cursor: .frameResize(position: .bottom, directions: .all))
        addCursorRect(NSRect(x: 0, y: h - c, width: c, height: c), cursor: .frameResize(position: .bottomLeft, directions: .all))
        addCursorRect(NSRect(x: w - c, y: h - c, width: c, height: c), cursor: .frameResize(position: .bottomRight, directions: .all))
        addCursorRect(NSRect(x: 0, y: 0, width: c, height: c), cursor: .frameResize(position: .topLeft, directions: .all))
        addCursorRect(NSRect(x: w - c, y: 0, width: c, height: c), cursor: .frameResize(position: .topRight, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
        // A title being edited (here or on another fence) is kept when the click lands elsewhere
        if window?.firstResponder is NSTextView { window?.makeFirstResponder(superview) }
        let start = convert(event.locationInWindow, from: nil)
        let grabbed = edges(at: start)
        if grabbed.isEmpty, chevronRect.contains(start) {
            onToggleCollapsed?()
            return
        }
        if grabbed.isEmpty, let backRect, backRect.contains(start) {
            portalView?.goUp()
            return
        }
        if grabbed.isEmpty, let openRect, openRect.contains(start), let folder = portalView?.currentFolder {
            AppDelegate.shared.openWindow(at: folder)
            return
        }
        // Double-click on the title bar (not on its text): roll up / down
        if grabbed.isEmpty, event.clickCount == 2, !titleTextHitRect.contains(start) {
            onToggleCollapsed?()
            return
        }
        let moved = track(from: event, edges: grabbed.isEmpty ? [.minX, .maxX, .minY, .maxY] : grabbed)
        // A click on the title's text (not a drag): rename it at once (a portal is named by its folder)
        if !moved, grabbed.isEmpty, !fence.isPortal, titleTextHitRect.contains(start) { beginRename() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(event) }

    /// Moves (all edges) or resizes (some) until the mouse goes up; snaps on the way.
    @discardableResult
    private func track(from event: NSEvent, edges: Set<NSRectEdge>) -> Bool {
        guard let superview, let window else { return false }
        // (Kept: moved onto another monitor, this view leaves its desktop while the drag goes on)
        let home = window.screen
        func screenFrame(_ rect: NSRect) -> NSRect { window.convertToScreen(superview.convert(rect, to: nil)) }
        func overOther() -> Bool {
            let mouse = NSEvent.mouseLocation
            guard let home, let there = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return false }
            return there != home
        }
        var elsewhere = false
        let startMouse = superview.convert(event.locationInWindow, from: nil)
        let startFrame = frame
        let moving = edges.count == 4
        var current = startFrame
        var moved = false
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let mouse = superview.convert(next.locationInWindow, from: nil)
            let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
            guard moved || hypot(dx, dy) > 2 else { continue }
            moved = true
            var rect = startFrame
            if moving {
                rect.origin.x += dx
                rect.origin.y += dy
            } else {
                if edges.contains(.minX) { rect.origin.x = min(startFrame.minX + dx, startFrame.maxX - minimumSize.width); rect.size.width = startFrame.maxX - rect.minX }
                if edges.contains(.maxX) { rect.size.width = max(startFrame.width + dx, minimumSize.width) }
                if edges.contains(.minY) { rect.origin.y = min(startFrame.minY + dy, startFrame.maxY - minimumSize.height); rect.size.height = startFrame.maxY - rect.minY }
                if edges.contains(.maxY) { rect.size.height = max(startFrame.height + dy, minimumSize.height) }
            }
            // Over another monitor: the fence (with its icons) is there now, following the mouse
            if moving, overOther() {
                elsewhere = true
                current = rect.integral
                frame = current
                onGuides?([])
                _ = onOtherMonitor?(screenFrame(current), false)
                continue
            }
            // ⌘ held: no snapping (fine positioning)
            if FenceStyle.snapping, !next.modifierFlags.contains(.command), let snap {
                let (snapped, guides) = snap(rect, edges)
                if snapped.width >= minimumSize.width - 0.5, snapped.height >= (fence.collapsed ? 0 : minimumSize.height - 0.5) { rect = snapped }
                onGuides?(guides)
            } else {
                onGuides?([])
            }
            // Kept on the monitor: the panel doesn't slide past its edge (its icons are laid out
            // inside the monitor, they'd be left behind)
            if let area = keepInside?() {
                if moving {
                    rect.origin.x = min(max(rect.minX, area.minX), area.maxX - rect.width)
                    rect.origin.y = min(max(rect.minY, area.minY), area.maxY - rect.height)
                } else {
                    if edges.contains(.minX), rect.minX < area.minX { rect.size.width -= area.minX - rect.minX; rect.origin.x = area.minX }
                    if edges.contains(.minY), rect.minY < area.minY { rect.size.height -= area.minY - rect.minY; rect.origin.y = area.minY }
                    if edges.contains(.maxX), rect.maxX > area.maxX { rect.size.width = area.maxX - rect.minX }
                    if edges.contains(.maxY), rect.maxY > area.maxY { rect.size.height = area.maxY - rect.minY }
                }
            }
            current = rect.integral
            frame = current
            onFrame?(current, false)
            // Back from another monitor: here again (its icons too)
            if elsewhere {
                elsewhere = false
                _ = onOtherMonitor?(nil, false)
            }
        }
        onGuides?([])
        // Let go over another monitor: it stays there (snapped to that monitor's edges and fences)
        if moved, moving, overOther(), onOtherMonitor?(screenFrame(current), true) == true {
            return true
        }
        if moved { onFrame?(current, true) }
        return moved
    }

    // MARK: Rename (inline, in the title bar)

    private var renameField: NSTextField?

    /// The title's font and where its text sits — the rename field puts its text exactly there.
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private var titleTextRect: NSRect {
        let height = ceil(Self.titleFont.ascender - Self.titleFont.descender + Self.titleFont.leading)
        return NSRect(x: 26, y: ((DesktopFence.titleHeight - height) / 2).rounded(), width: bounds.width - 52, height: height)
    }

    /// The title's text itself (as wide as the words, a little padding around them).
    private var titleTextHitRect: NSRect {
        let area = titleTextRect
        let width = min((shownTitle as NSString).size(withAttributes: [.font: Self.titleFont]).width, area.width)
        return NSRect(x: area.midX - width / 2 - 6, y: 0, width: width + 12, height: DesktopFence.titleHeight)
    }

    func beginRename() {
        guard renameField == nil else { return }
        // A borderless field over the title's own text (the cell insets its text by 2 pt each side)
        let field = NSTextField(frame: titleTextRect.insetBy(dx: -2, dy: 0))
        field.stringValue = fence.title
        field.font = Self.titleFont
        field.alignment = .center
        field.focusRingType = .none
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(field)
        renameField = field
        window?.makeKey()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        redraw()
    }

    /// Return, or a click anywhere else: the new title is kept. Esc: the old one stays.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = renameField else { return }
        let cancelled = (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        let title = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        renameField = nil
        redraw()
        if !cancelled, !title.isEmpty, title != fence.title { onRename?(title) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renameField?.stringValue = fence.title
        window?.makeFirstResponder(superview)
        return true
    }

    // MARK: Drawing

    fileprivate func drawContent(_ dirtyRect: NSRect) {
        let radius = min(FenceStyle.cornerRadius, bounds.height / 2)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let tint = FenceStyle.nsColor(fence.color ?? FenceStyle.color) ?? .black
        tint.withAlphaComponent(min(1, FenceStyle.opacity + (isDropTarget ? 0.1 : 0))).setFill()
        shape.fill()
        (isDropTarget ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.22)).setStroke()
        shape.lineWidth = isDropTarget ? 2 : 1
        shape.stroke()
        if !fence.collapsed {
            // The title bar, a shade darker, with a hairline under it
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.black.withAlphaComponent(0.18).setFill()
            titleRect.fill()
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSRect(x: 0, y: titleRect.maxY - 1, width: bounds.width, height: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if renameField != nil {
            // Editing: a soft field behind the text (the text itself doesn't move)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: titleTextRect.insetBy(dx: -6, dy: -3), xRadius: 6, yRadius: 6).fill()
            return
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont, .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow,
        ]
        let text = NSAttributedString(string: shownTitle, attributes: attributes)
        if fence.collapsed && !fence.members.isEmpty {
            // How many icons it holds: a small badge at the right, the title stays the same
            let count = NSAttributedString(string: "\(fence.members.count)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ])
            let size = count.size()
            let badge = NSRect(x: bounds.width - size.width - 22 - (fence.isPortal ? 28 : 0), y: (DesktopFence.titleHeight - 18) / 2, width: size.width + 12, height: 18)
            NSColor.white.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9).fill()
            count.draw(at: NSPoint(x: badge.minX + 6, y: badge.midY - size.height / 2))
        }
        text.draw(in: titleTextRect)
        // Roll-up chevron at the left
        if let chevron = NSImage(systemSymbolName: fence.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
            let tinted = NSImage(size: chevron.size, flipped: false) { rect in
                chevron.draw(in: rect)
                NSColor.white.withAlphaComponent(0.7).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 12, y: (DesktopFence.titleHeight - chevron.size.height) / 2,
                                   width: chevron.size.width, height: chevron.size.height))
        }
        // Portal buttons: back (in a subfolder) and "open in WinEx"
        func symbol(_ name: String, in rect: NSRect) {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) else { return }
            let white = NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r)
                NSColor.white.withAlphaComponent(0.8).set()
                r.fill(using: .sourceAtop)
                return true
            }
            white.draw(in: NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
        }
        if let backRect { symbol("chevron.left", in: backRect) }
        if let openRect { symbol("arrow.up.forward.app", in: openRect) }
    }
}

/// Draws the fence (panel, title, buttons) above its frosted glass; the mouse goes to the fence.
private final class FenceOverlay: NSView {
    weak var owner: FenceView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawContent(dirtyRect) }
}

/// Where a zone would go: the empty area just selected, outlined with a dashed line.
final class FenceAreaOutline: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: FenceStyle.cornerRadius, yRadius: FenceStyle.cornerRadius)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        shape.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        shape.lineWidth = 1.5
        shape.setLineDash([6, 4], count: 2, phase: 0)
        shape.stroke()
    }
}

/// The accent-coloured lines a fence snaps to, while it's moved or resized.
final class FenceGuidesView: NSView {
    var guides: [FenceSnap.Guide] = [] { didSet { if guides != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        for guide in guides {
            let path = NSBezierPath()
            if guide.vertical {
                path.move(to: NSPoint(x: guide.position, y: guide.from))
                path.line(to: NSPoint(x: guide.position, y: guide.to))
            } else {
                path.move(to: NSPoint(x: guide.from, y: guide.position))
                path.line(to: NSPoint(x: guide.to, y: guide.position))
            }
            path.lineWidth = 1.5
            path.setLineDash([5, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}

/// The translucent hint under several selected desktop icons: «Поместить в ограду  ⌘G».
@MainActor
final class FenceHintButton: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var title = NSAttributedString()
    private var shortcut = NSAttributedString()

    /// "Поместить в зону" for selected icons, "Создать зону здесь" for an empty area.
    func configure(title text: String, tip: String) {
        guard text != title.string else { return }
        title = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        shortcut = NSAttributedString(string: "⌘G", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ])
        toolTip = tip
        setFrameSize(intrinsicContentSize)
        needsDisplay = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 15
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        blur.alphaValue = 0.7
        addSubview(blur)
        configure(title: L("Поместить в зону"), tip: L("Объединить выделенные значки в зону"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: 16 + 16 + 6 + title.size().width + 10 + shortcut.size().width + 14, height: 30)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 15, yRadius: 15)
        NSColor.black.withAlphaComponent(hovering ? 0.45 : 0.3).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        shape.stroke()
        var x: CGFloat = 16
        if let icon = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
            let white = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            white.draw(in: NSRect(x: x, y: (bounds.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            x += icon.size.width + 6
        }
        title.draw(at: NSPoint(x: x, y: (bounds.height - title.size().height) / 2))
        x += title.size().width + 10
        shortcut.draw(at: NSPoint(x: x, y: (bounds.height - shortcut.size().height) / 2))
    }
}
