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
        startGuard()
    }

    static func restore() {
        stopGuard()
        run("/usr/bin/defaults", "delete", "-g", "NSFileViewer")
        run("/usr/bin/defaults", "delete", "com.apple.finder", "CreateDesktop")
        restartFinder()
        isApplied = false
    }

    // MARK: - Crash guard

    private static var guardProcess: Process?

    /// If WinEx dies without restoring (crash, force quit, kill -9), Finder would be left without a
    /// desktop and nobody drawing one. A tiny shell process outlives us (it is reparented to launchd),
    /// waits for our PID to disappear and puts Finder back if the desktop is still hidden.
    /// A normal quit stops it first, so Finder isn't restarted twice.
    private static func startGuard() {
        stopGuard()
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 1; done
            if [ "$(/usr/bin/defaults read com.apple.finder CreateDesktop 2>/dev/null)" = "0" ]; then
              /usr/bin/defaults delete -g NSFileViewer 2>/dev/null
              /usr/bin/defaults delete com.apple.finder CreateDesktop 2>/dev/null
              /usr/bin/killall Finder 2>/dev/null
            fi
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            guardProcess = process
        } catch {
            NSLog("WinEx: could not start the Finder guard: \(error)")
        }
    }

    private static func stopGuard() {
        guardProcess?.terminate()
        guardProcess = nil
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
