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

    var frame: NSRect {
        get { NSRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }

    static let titleHeight: CGFloat = 30
    static let padding: CGFloat = 6
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

    /// `rect` with its moving edges pulled onto the nearest target lines (within the threshold).
    /// `edges`: which sides move (all four when the whole rect moves). Targets: the area's edges,
    /// the other rects' edges (lined up with them, or `gap` away from them side by side).
    static func snap(_ rect: NSRect, edges: Set<NSRectEdge>, area: NSRect, others: [NSRect]) -> (NSRect, [Guide]) {
        let moving = edges.count == 4
        var xs: [CGFloat] = [area.minX + gap, area.maxX - gap]
        var ys: [CGFloat] = [area.minY + gap, area.maxY - gap]
        for other in others {
            xs += [other.minX, other.maxX, other.maxX + gap, other.minX - gap]
            ys += [other.minY, other.maxY, other.maxY + gap, other.minY - gap]
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
                guide.vertical ? [other.minX, other.maxX, other.maxX + gap, other.minX - gap].contains(guide.position)
                               : [other.minY, other.maxY, other.maxY + gap, other.minY - gap].contains(guide.position)
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
    var fence: DesktopFence { didSet { if fence != oldValue { needsDisplay = true; updateBlur() } } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    /// Hidden icons below the visible rows (shown as "↓ N").
    var overflow = 0 { didSet { if overflow != oldValue { needsDisplay = true } } }

    /// Live frame while moving / resizing (with the snapping guides), then the final one.
    var onFrame: ((NSRect, _ final: Bool) -> Void)?
    var snap: ((NSRect, Set<NSRectEdge>) -> (NSRect, [FenceSnap.Guide]))?
    var onGuides: (([FenceSnap.Guide]) -> Void)?
    var onToggleCollapsed: (() -> Void)?
    var onMenu: ((NSEvent) -> NSMenu?)?
    var onRename: ((String) -> Void)?
    var minimumSize = NSSize(width: 140, height: 120)

    private let blur = NSVisualEffectView()
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
        updateBlur()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateBlur() {
        blur.alphaValue = 0.55
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

    /// The title bar and the edges; the inside belongs to the desktop (icons, rubber band, drops).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if renameField.map({ $0.frame.contains(local) }) == true { return renameField }
        return titleRect.contains(local) || !edges(at: local).isEmpty ? self : nil
    }

    override func resetCursorRects() {
        let e = Self.edge, c = Self.corner, w = bounds.width, h = bounds.height
        addCursorRect(chevronRect.insetBy(dx: 0, dy: 4), cursor: .pointingHand)
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
        let moved = track(from: event, edges: grabbed.isEmpty ? [.minX, .maxX, .minY, .maxY] : grabbed)
        // A click on the title (not a drag): rename it at once. Rolling up is the chevron's job.
        if !moved, grabbed.isEmpty { beginRename() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(event) }

    /// Moves (all edges) or resizes (some) until the mouse goes up; snaps on the way.
    @discardableResult
    private func track(from event: NSEvent, edges: Set<NSRectEdge>) -> Bool {
        guard let superview else { return false }
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
            // ⌘ held: no snapping (fine positioning)
            if !next.modifierFlags.contains(.command), let snap {
                let (snapped, guides) = snap(rect, edges)
                if snapped.width >= minimumSize.width - 0.5, snapped.height >= (fence.collapsed ? 0 : minimumSize.height - 0.5) { rect = snapped }
                onGuides?(guides)
            } else {
                onGuides?([])
            }
            current = rect.integral
            frame = current
            onFrame?(current, false)
        }
        onGuides?([])
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
        needsDisplay = true
    }

    /// Return, or a click anywhere else: the new title is kept. Esc: the old one stays.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = renameField else { return }
        let cancelled = (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        let title = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        renameField = nil
        needsDisplay = true
        if !cancelled, !title.isEmpty, title != fence.title { onRename?(title) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renameField?.stringValue = fence.title
        window?.makeFirstResponder(superview)
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(isDropTarget ? 0.32 : 0.22).setFill()
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
        let text = NSAttributedString(string: fence.title, attributes: attributes)
        if fence.collapsed && !fence.members.isEmpty {
            // How many icons it holds: a small badge at the right, the title stays the same
            let count = NSAttributedString(string: "\(fence.members.count)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ])
            let size = count.size()
            let badge = NSRect(x: bounds.width - size.width - 22, y: (DesktopFence.titleHeight - 18) / 2, width: size.width + 12, height: 18)
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
        if overflow > 0 && !fence.collapsed {
            let more = NSAttributedString(string: "↓ \(overflow)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            ])
            let size = more.size()
            more.draw(at: NSPoint(x: bounds.width - size.width - 10, y: bounds.height - size.height - 5))
        }
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
    private let title = NSAttributedString(string: L("Поместить в ограду"), attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
    ])
    private let shortcut = NSAttributedString(string: "⌘G", attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.6),
    ])

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
        setFrameSize(intrinsicContentSize)
        toolTip = L("Объединить выделенные значки в ограду")
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
