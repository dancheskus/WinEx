import AppKit
import ServiceManagement

// scripts/reset-to-fresh.sh: take WinEx out of the login items (only the app itself can) and quit
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

Localization.start()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
