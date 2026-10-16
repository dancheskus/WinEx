import AppKit
import Testing
@testable import WinEx

/// Dragging a window by its title bar: the grabbed point stays under the mouse, also when macOS
/// gives the window another size on the way (taken off half of the screen).
@MainActor @Suite struct WindowGrabTests {
    @Test func theGrabbedPointStaysUnderTheMouseWhenTheWindowShrinks() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.setFrame(NSRect(x: 100, y: 100, width: 800, height: 600), display: false)
        // Grabbed 10 pt below the top, in the middle
        let grab = WindowGrab(window: window, mouse: NSPoint(x: 500, y: 690))
        // Taken off half of the screen: its own, smaller size again
        window.setFrame(NSRect(x: 100, y: 100, width: 400, height: 300), display: false)
        let mouse = NSPoint(x: 520, y: 680)
        let origin = grab.origin(for: window, mouse: mouse)
        #expect(origin.y + 300 - mouse.y == 10)            // still 10 pt below the top
        #expect(mouse.x - origin.x == 200)                 // still in the middle
    }
}
