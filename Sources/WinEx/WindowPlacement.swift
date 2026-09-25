import AppKit

/// Where the last used folder window was: its frame and the monitor it was on. A new window opened
/// when no other is open comes back there (further windows cascade from the open ones).
enum WindowPlacement {
    struct Saved: Codable, Equatable {
        /// Window frame in global screen coordinates.
        var frame: CGRect
        /// The monitor: a stable display UUID and its frame at that time.
        var screenID: String
        var screenFrame: CGRect
    }

    struct Screen {
        var id: String
        var frame: CGRect
        var visibleFrame: CGRect
    }

    private static let defaultsKey = "lastWindowPlacement"

    @MainActor
    static var saved: Saved? {
        get { AppDefaults.store.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } }
        set { AppDefaults.store.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: defaultsKey) }
    }

    /// Remembers `window` as the last used one (called when it's moved, resized or closed).
    @MainActor
    static func remember(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), window.isVisible,
              let screen = window.screen, let id = screen.displayUUID else { return }
        saved = Saved(frame: window.frame, screenID: id, screenFrame: screen.frame)
    }

    /// The saved frame, if there is one, adjusted to the monitors connected now.
    @MainActor
    static func restoredFrame() -> CGRect? {
        guard let saved else { return nil }
        let screens = NSScreen.screens.compactMap { screen in
            screen.displayUUID.map { Screen(id: $0, frame: screen.frame, visibleFrame: screen.visibleFrame) }
        }
        return frame(for: saved, screens: screens)
    }

    /// On the same monitor, even if the monitors were rearranged since; if that monitor is gone,
    /// at the same spot of the main one. Always fits inside the monitor's visible area.
    static func frame(for saved: Saved, screens: [Screen]) -> CGRect? {
        guard let main = screens.first else { return nil }
        let target = screens.first { $0.id == saved.screenID }
        let screen = target ?? main
        var frame = saved.frame
        // Keep the offset from the monitor's corner
        frame.origin.x += screen.frame.minX - saved.screenFrame.minX
        frame.origin.y += screen.frame.minY - saved.screenFrame.minY
        let visible = screen.visibleFrame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }
}

extension NSScreen {
    /// A display identifier that survives reboots and reconnection (unlike the display number).
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
