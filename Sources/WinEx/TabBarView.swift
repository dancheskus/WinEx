import AppKit

/// Chrome-style tab strip: click to select, drag to reorder, drag far enough
/// out of the strip to tear the tab off into its own window.
final class TabBarView: NSView {
    private static let detachDistance: CGFloat = 30
    private static let maxTabWidth: CGFloat = 220
    private static let minTabWidth: CGFloat = 70
    /// Pill-shaped tabs, vertically centred in the title bar.
    private static let tabHeight: CGFloat = 30

    weak var controller: ExplorerWindowController?

    private var itemViews: [TabItemView] = []
    private let addButton = NSButton()
    /// While reordering: index of the dragged tab and its current x.
    private var dragState: (index: Int, x: CGFloat)?
    /// A tab dragged in from another window, shown in the strip before the drop (Chrome).
    private var incoming: (view: TabItemView, index: Int)?
    /// The window whose strip shows our dragged tab right now.
    private weak var mergePreview: ExplorerWindowController?
    private var slotCount: Int { itemViews.count + (incoming == nil ? 0 : 1) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("Новая вкладка"))
        addButton.isBordered = false
        addButton.bezelStyle = .accessoryBarAction
        addButton.target = self
        addButton.action = #selector(addTab(_:))
        addButton.toolTip = L("Новая вкладка (⌘T)")
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
        let perTab = available / CGFloat(max(slotCount, 1))
        return min(Self.maxTabWidth, max(Self.minTabWidth, perTab))
    }

    private func frameForTab(at index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * tabWidth, y: ((bounds.height - Self.tabHeight) / 2).rounded(),
               width: tabWidth, height: Self.tabHeight)
    }

    override func layout() {
        super.layout()
        layoutTabs(animated: false)
    }

    private func layoutTabs(animated: Bool) {
        if let incoming {
            let frame = frameForTab(at: incoming.index)
            if animated { incoming.view.animator().frame = frame } else { incoming.view.frame = frame }
        }
        for (i, view) in itemViews.enumerated() {
            // Tabs after an incoming one make room for it
            var frame = frameForTab(at: i + (incoming.map { i >= $0.index ? 1 : 0 } ?? 0))
            if let drag = dragState, drag.index == i {
                frame.origin.x = drag.x
                view.frame = frame
            } else if animated {
                view.animator().frame = frame
            } else {
                view.frame = frame
            }
        }
        let addX = CGFloat(slotCount) * tabWidth + 6
        addButton.frame = NSRect(x: addX, y: ((bounds.height - 24) / 2).rounded(), width: 24, height: 24)
    }

    /// While a tab from another window is over this strip: it snaps in here, the others move
    /// aside — so it's clear before the drop that the tab will join this window.
    func showIncoming(title: String, icon: NSImage?, atScreenPoint point: NSPoint) {
        let index = insertionIndex(forScreenPoint: point)
        if let incoming, incoming.index == index { return }
        let view: TabItemView
        if let current = incoming?.view {
            view = current
        } else {
            view = TabItemView(tabID: UUID())
            view.title = title
            view.icon = icon
            view.isSelected = true
            view.alphaValue = 0
            view.frame = frameForTab(at: index)
            addSubview(view, positioned: .below, relativeTo: addButton)
        }
        incoming = (view, index)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            view.animator().alphaValue = 1
            layoutTabs(animated: true)
        }
    }

    func clearIncoming() {
        guard let view = incoming?.view else { return }
        incoming = nil
        view.removeFromSuperview()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            layoutTabs(animated: true)
        }
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
                // Over another window's tabs: the window fades out and its tab snaps into that
                // strip; away from it, the window comes back (Chrome)
                let target = AppDelegate.shared.mergeTarget(for: floating, at: mouse)
                if target !== mergePreview { mergePreview?.tabBar.clearIncoming() }
                if let target, let source = floating.windowController as? ExplorerWindowController {
                    if target !== mergePreview { target.window?.order(.below, relativeTo: floating.windowNumber) }
                    target.tabBar.showIncoming(title: source.selectedTab.title, icon: source.selectedTab.location.icon, atScreenPoint: mouse)
                    floating.alphaValue = 0
                } else {
                    floating.alphaValue = 1
                }
                mergePreview = target
                continue
            }

            let local = convert(window.convertPoint(fromScreen: mouse), from: nil)
            let outside = local.y < -Self.detachDistance || local.y > bounds.height + Self.detachDistance
            if outside {
                dragState = nil
                let newWindow = controller.detachTab(at: index)
                // Keep the grabbed point of the tab under the cursor
                let stripX = (newWindow.windowController as? ExplorerWindowController)?.tabBarOriginX ?? 0
                windowGrabOffset = NSPoint(x: stripX + grabOffsetX,
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
        mergePreview?.tabBar.clearIncoming()
        mergePreview = nil
        if let floating = floatingWindow {
            AppDelegate.shared.windowDragEnded(floating, at: lastMouse)
            floating.alphaValue = 1
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
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Закрыть вкладку"))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.toolTip = L("Закрыть вкладку (⌘W)")
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
        // macOS 26 tabs: a soft pill for the selected one, a lighter one under the mouse
        guard isSelected || hovering else { return }
        (isSelected ? NSColor.labelColor.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 9, yRadius: 9).fill()
    }

    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
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
