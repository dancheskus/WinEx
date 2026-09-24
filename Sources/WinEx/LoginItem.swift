import AppKit
import ServiceManagement

/// "Открывать при входе в систему": WinEx as a login item (System Settings ▸ General ▸ Login Items).
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS may want the user to allow it in System Settings first.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// True when this launch comes from logging in (the "open application" Apple event says so).
    static func launchedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication,
              let reason = event.paramDescriptor(forKeyword: keyAEPropData) else { return false }
        return reason.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
