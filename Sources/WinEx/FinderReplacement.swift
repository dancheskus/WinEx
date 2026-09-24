import AppKit

/// Switches the system between "Finder" mode and "WinEx replaces Finder" mode.
///
/// Replacement mode:
///  - `NSFileViewer` → WinEx, so "Show in Finder" in most apps reveals files in WinEx;
///  - Finder stops drawing the desktop (WinEx draws its own, see `DesktopController`).
///
/// Becoming the default app for folders is not possible: on macOS 26+ LaunchServices rejects
/// changing the `public.folder` handler with paramErr (-50), so `open <folder>` from other
/// apps still goes to Finder.
@MainActor
enum FinderReplacement {
    private(set) static var isApplied = false

    private static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    static func apply() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            NSLog("WinEx: no bundle identifier — run the packaged WinEx.app, not the bare binary")
            return
        }
        run("/usr/bin/defaults", "write", "-g", "NSFileViewer", "-string", bundleID)
        run("/usr/bin/defaults", "write", "com.apple.finder", "CreateDesktop", "-bool", "false")
        restartFinder()
        isApplied = true
    }

    static func restore() {
        run("/usr/bin/defaults", "delete", "-g", "NSFileViewer")
        run("/usr/bin/defaults", "delete", "com.apple.finder", "CreateDesktop")
        restartFinder()
        isApplied = false
    }

    /// Finder rereads CreateDesktop only on launch. Killing it makes launchd start it again;
    /// if it was not running at all, launch it explicitly.
    private static func restartFinder() {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty
        if running {
            run("/usr/bin/killall", "Finder")
        } else {
            NSWorkspace.shared.openApplication(at: finderURL, configuration: .init())
        }
    }

    private static func run(_ tool: String, _ args: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("WinEx: failed to run \(tool): \(error)")
        }
    }
}
