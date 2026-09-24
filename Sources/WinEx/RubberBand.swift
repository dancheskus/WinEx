import AppKit

/// Explorer-style selection rectangle, drawn over a table or collection view while dragging
/// on empty space. Scrolls the view when the mouse goes past its edge.
@MainActor
enum RubberBand {
    /// Runs until mouse up; `update` receives the rectangle (in `view` coordinates) after every move.
    static func track(in view: NSView, from start: NSPoint, update: (NSRect) -> Void) {
        let overlay = RubberBandView(frame: NSRect(origin: start, size: .zero))
        view.addSubview(overlay)
        defer { overlay.removeFromSuperview() }

        // Periodic events keep auto-scrolling while the mouse rests past the edge
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }

        var lastDrag: NSEvent?
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if event.type == .leftMouseUp { break }
            if event.type == .leftMouseDragged { lastDrag = event }
            guard let drag = lastDrag else { continue }
            view.autoscroll(with: drag)
            let point = view.convert(drag.locationInWindow, from: nil)
            let rect = NSRect(x: min(point.x, start.x), y: min(point.y, start.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            overlay.frame = rect
            update(rect)
        }
    }
}

private final class RubberBandView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).setFill()
        bounds.fill(using: .sourceOver)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}
