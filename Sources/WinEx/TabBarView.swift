import AppKit

/// Chrome-style tab strip: click to select, drag to reorder, drag far enough
/// out of the strip to tear the tab off into its own window.
final class TabBarView: NSView {
    static let height: CGFloat = 38
    private static let detachDistance: CGFloat = 30
    private static let maxTabWidth: CGFloat = 220
    private static let minTabWidth: CGFloat = 70
    private static let topInset: CGFloat = 6

    weak var controller: ExplorerWindowController?

    private var itemViews: [TabItemView] = []
    private let addButton = NSButton()
    /// While reordering: index of the dragged tab and its current x.
    private var dragState: (index: Int, x: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Новая вкладка")
        addButton.isBordered = false
        addButton.bezelStyle = .accessoryBarAction
        addButton.target = self
        addButton.action = #selector(addTab(_:))
        addButton.toolTip = "Новая вкладка (⌘T)"
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var screenFrame: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    // MARK: - Model sync

    func reload() {
        guard let controller else { return }
        let existing = Dictionary(uniqueKeysWithValues: itemViews.map { ($0.tabID, $0) })
        var views: [TabItemView] = []
        for (i, tab) in controller.tabs.enumerated() {
            let view = existing[tab.id] ?? makeItemView(for: tab)
            view.title = tab.title
            view.icon = tab.location.icon
            view.isSelected = i == controller.selectedIndex
            views.append(view)
        }
        for view in itemViews where !views.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        itemViews = views
        needsLayout = true
    }

    private func makeItemView(for tab: ExplorerTab) -> TabItemView {
        let view = TabItemView(tabID: tab.id)
        view.onClose = { [weak self, weak view] in
            guard let self, let view, let i = self.itemViews.firstIndex(where: { $0 === view }) else { return }
            self.controller?.closeTab(at: i)
        }
        addSubview(view, positioned: .below, relativeTo: addButton)
        return view
    }

    // MARK: - Layout

    private var tabWidth: CGFloat {
        let available = bounds.width - 40
        let perTab = available / CGFloat(max(itemViews.count, 1))
        return min(Self.maxTabWidth, max(Self.minTabWidth, perTab))
    }

    private func frameForTab(at index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * tabWidth, y: Self.topInset,
               width: tabWidth, height: bounds.height - Self.topInset)
    }

    override func layout() {
        super.layout()
        layoutTabs(animated: false)
    }

    private func layoutTabs(animated: Bool) {
        for (i, view) in itemViews.enumerated() {
            var frame = frameForTab(at: i)
            if let drag = dragState, drag.index == i {
                frame.origin.x = drag.x
                view.frame = frame
            } else if animated {
                view.animator().frame = frame
            } else {
                view.frame = frame
            }
        }
        let addX = CGFloat(itemViews.count) * tabWidth + 6
        let tabHeight = bounds.height - Self.topInset
        addButton.frame = NSRect(x: addX, y: Self.topInset + (tabHeight - 24) / 2, width: 24, height: 24)
    }

    func insertionIndex(forScreenPoint point: NSPoint) -> Int {
        guard let window else { return itemViews.count }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let index = Int((local.x / tabWidth).rounded())
        return min(max(index, 0), itemViews.count)
    }

    // MARK: - Mouse

    @objc private func addTab(_ sender: Any?) {
        controller?.newTab(sender)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = itemViews.firstIndex(where: { $0.frame.contains(point) }) else {
            // Empty strip behaves like a title bar
            WindowDragArea.handle(event, in: window)
            return
        }
        controller.selectTab(at: index)
        trackDrag(ofTabAt: index, startPoint: point, startMouse: Self.screenLocation(of: event))
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle click closes a tab
        let point = convert(event.locationInWindow, from: nil)
        if event.buttonNumber == 2, let index = itemViews.firstIndex(where: { $0.frame.contains(point) }) {
            controller?.closeTab(at: index)
        }
    }

    /// Mouse position of an event in screen coordinates.
    private static func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// Runs a local event loop until mouse up. Handles reordering inside the strip,
    /// tearing a tab off into a new window, and moving that window around.
    private func trackDrag(ofTabAt startIndex: Int, startPoint: NSPoint, startMouse: NSPoint) {
        guard let window, let controller else { return }
        let grabOffsetX = startPoint.x - itemViews[startIndex].frame.minX
        var index = startIndex
        var dragging = false
        // Window that follows the mouse: either a torn-off tab's window, or our own
        // window when it has a single tab (dragging the only tab drags the window).
        var floatingWindow: NSWindow?
        var windowGrabOffset = NSPoint.zero
        var lastMouse = startMouse

        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let mouse = Self.screenLocation(of: event)
            lastMouse = mouse
            if event.type == .leftMouseUp { break }

            if !dragging {
                guard hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) >= 4 else { continue }
                dragging = true
                if controller.tabs.count == 1 {
                    floatingWindow = window
                    windowGrabOffset = NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
                }
            }

            if let floating = floatingWindow {
                floating.setFrameOrigin(NSPoint(x: mouse.x - windowGrabOffset.x, y: mouse.y - windowGrabOffset.y))
                continue
            }

            let local = convert(window.convertPoint(fromScreen: mouse), from: nil)
            let outside = local.y < -Self.detachDistance || local.y > bounds.height + Self.detachDistance
            if outside {
                dragState = nil
                let newWindow = controller.detachTab(at: index)
                // Keep the grabbed point of the tab under the cursor
                windowGrabOffset = NSPoint(x: ExplorerWindowController.tabBarLeadingInset + grabOffsetX,
                                           y: newWindow.frame.height - startPoint.y)
                newWindow.setFrameOrigin(NSPoint(x: mouse.x - windowGrabOffset.x, y: mouse.y - windowGrabOffset.y))
                floatingWindow = newWindow
                needsLayout = true
                continue
            }

            // Reorder within the strip
            let maxX = CGFloat(itemViews.count - 1) * tabWidth
            let x = min(max(local.x - grabOffsetX, 0), maxX)
            let target = min(max(Int((x + tabWidth / 2) / tabWidth), 0), itemViews.count - 1)
            if target != index {
                controller.moveTab(from: index, to: target)
                index = target
            }
            // Keep the dragged tab on top
            addSubview(itemViews[index], positioned: .below, relativeTo: addButton)
            dragState = (index, x)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                layoutTabs(animated: true)
            }
        }

        dragState = nil
        if let floating = floatingWindow {
            AppDelegate.shared.windowDragEnded(floating, at: lastMouse)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            layoutTabs(animated: true)
        }
    }
}

/// A single tab in the strip. Mouse events on the body fall through to `TabBarView`.
final class TabItemView: NSView {
    let tabID: UUID
    var onClose: (() -> Void)?

    var title = "" {
        didSet { label.stringValue = title; toolTip = title }
    }
    var icon: NSImage? {
        didSet { iconView.image = icon }
    }
    var isSelected = false {
        didSet { needsDisplay = true; label.textColor = isSelected ? .labelColor : .secondaryLabelColor }
    }

    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let closeButton = NSButton()

    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Закрыть вкладку")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.toolTip = "Закрыть вкладку (⌘W)"
        [iconView, label, closeButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Tabs sit in the title bar area; non-opaque views there default to "drag the window",
    /// and the window server would move the window before we ever see the drag.
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func close(_ sender: Any?) { onClose?() }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        iconView.frame = NSRect(x: 10, y: midY - 8, width: 16, height: 16)
        closeButton.frame = NSRect(x: bounds.width - 26, y: midY - 8, width: 16, height: 16)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: 32, y: midY - labelHeight / 2,
                             width: max(0, closeButton.frame.minX - 36), height: labelHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        return closeButton.frame.contains(local) ? closeButton : self
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            // Rounded top corners, square bottom that merges into the nav bar
            let rect = bounds.insetBy(dx: 1, dy: 0)
            let path = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 10),
                                    xRadius: 8, yRadius: 8)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
        } else {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: 9, width: 1, height: bounds.height - 18).fill(using: .sourceOver)
        }
    }
}

/// Title bar behaviour for windows that aren't movable by the window server:
/// drag moves the window, double-click zooms (or minimizes, per System Settings).
final class WindowDragArea: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        Self.handle(event, in: window)
    }

    static func handle(_ event: NSEvent, in window: NSWindow) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
            return
        }
        let start = NSEvent.mouseLocation
        let origin = window.frame.origin
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                         inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let mouse = NSEvent.mouseLocation
            var frame = window.frame
            frame.origin = NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y)
            // Keep the title bar below the menu bar, like the system does
            if let screen = window.screen ?? NSScreen.main {
                frame.origin.y = min(frame.origin.y, screen.visibleFrame.maxY - frame.height)
            }
            window.setFrameOrigin(frame.origin)
        }
    }
}
