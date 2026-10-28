import AppKit

/// A WinEx stack in the Dock: a tiny app WinEx makes for each folder put there (its Info.plist
/// says which). It stays running without a Dock dot or a menu bar; a click on its tile asks WinEx
/// to show the folder's stack above it (where the mouse is), files dropped on the tile go into
/// the folder. WinEx draws everything; this only passes the click on.
final class StackHelper: NSObject, NSApplicationDelegate {
    private let info = Bundle.main.infoDictionary ?? [:]
    private var stackID: String { info["WinExStackID"] as? String ?? "" }
    private var winexID: String { info["WinExBundleID"] as? String ?? "dev.winex.WinEx" }
    /// Started by WinEx ahead of time (so the first click is quick): no stack then.
    private let inBackground = CommandLine.arguments.contains("--background")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quits with WinEx (it starts this again when it starts): nothing of WinEx's is left
        // running once WinEx is quit. A click on the tile then starts this, and this WinEx.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [winexID] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == winexID,
                  NSRunningApplication.runningApplications(withBundleIdentifier: winexID).isEmpty else { return }
            NSApp.terminate(nil)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A plain launch (a click on the tile while this wasn't running) — not one for dropped files
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openApplication(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenApplication))
    }

    @objc private func openApplication(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        if !inBackground { send("show") }
    }

    /// A click on the tile while running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        send("show")
        return false
    }

    /// Files dropped on the tile.
    func application(_ application: NSApplication, open urls: [URL]) {
        send("drop", paths: urls.map(\.path))
    }

    private func send(_ action: String, paths: [String] = []) {
        let mouse = NSEvent.mouseLocation
        if let winex = NSRunningApplication.runningApplications(withBundleIdentifier: winexID).first {
            // WinEx shows the stack in its own window: it may come forward when something is opened
            NSApp.yieldActivation(to: winex)
            let userInfo: [String: Any] = ["id": stackID, "action": action, "x": mouse.x, "y": mouse.y, "paths": paths]
            DistributedNotificationCenter.default().postNotificationName(.init("dev.winex.WinEx.stack"), object: stackID,
                                                                         userInfo: userInfo, deliverImmediately: true)
            return
        }
        // WinEx isn't running: started with the request
        let path = info["WinExAppPath"] as? String
        guard let app = path.map(URL.init(fileURLWithPath:)).flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: winexID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--stack", stackID, action, "\(mouse.x)", "\(mouse.y)"] + paths
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}

let app = NSApplication.shared
let delegate = StackHelper()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
