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

extension WindowPlacement {
    /// For a window that is mostly off the monitors (a monitor was unplugged): the frame moved
    /// (and shrunk if needed) onto the monitor showing most of it, or the first one. Nil when
    /// enough of it is visible already.
    static func fitted(_ frame: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        guard let first = visibleFrames.first, frame.width > 0, frame.height > 0 else { return nil }
        func overlap(_ area: CGRect) -> CGFloat {
            let part = area.intersection(frame)
            return part.isNull ? 0 : part.width * part.height
        }
        let visible = visibleFrames.map(overlap).reduce(0, +)
        // Most of it on screen, including the top strip (tabs and window buttons): leave it
        let top = CGRect(x: frame.minX, y: frame.maxY - 40, width: frame.width, height: 40)
        let topVisible = visibleFrames.map { $0.intersection(top) }.filter { !$0.isNull }.map { $0.width }.reduce(0, +)
        if visible >= frame.width * frame.height * 0.75, topVisible >= min(200, frame.width * 0.5) { return nil }
        let target = visibleFrames.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil } ?? first
        var result = frame
        result.size.width = min(frame.width, target.width)
        result.size.height = min(frame.height, target.height)
        result.origin.x = min(max(frame.minX, target.minX), target.maxX - result.width)
        result.origin.y = min(max(frame.minY, target.minY), target.maxY - result.height)
        return result
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
