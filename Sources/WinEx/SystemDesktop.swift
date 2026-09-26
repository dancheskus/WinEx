import AppKit

/// macOS desktop behaviours WinEx has to reproduce once Finder no longer draws the desktop.
@MainActor
enum SystemDesktop {
    private static func pref(_ key: String, in domain: String) -> Bool? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool
    }

    private static var stageManagerOn: Bool {
        pref("GloballyEnabled", in: "com.apple.WindowManager") ?? false
    }

    /// System Settings ▸ Desktop & Dock ▸ "Click wallpaper to reveal desktop": Always (default) or only in Stage Manager.
    static var clickRevealsDesktop: Bool {
        stageManagerOn || (pref("EnableStandardClickToShowDesktop", in: "com.apple.WindowManager") ?? true)
    }

    /// Desktop & Dock ▸ "Show Items: On Desktop / In Stage Manager".
    static var hidesDesktopItems: Bool {
        stageManagerOn
            ? (pref("HideDesktop", in: "com.apple.WindowManager") ?? true)
            : (pref("StandardHideDesktopIcons", in: "com.apple.WindowManager") ?? false)
    }

    /// Keyboard ▸ Shortcuts ▸ Mission Control ▸ "Show Desktop" is F11 (as out of the box): macOS
    /// takes the key before any program sees it.
    static var f11ShowsDesktop: Bool {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any],
              let entry = all["36"] as? [String: Any] else { return true }
        guard (entry["enabled"] as? Bool) ?? (entry["enabled"] as? Int == 1) else { return false }
        let parameters = ((entry["value"] as? [String: Any])?["parameters"] as? [Int]) ?? []
        return parameters.count == 3 && parameters[1] == 103 && parameters[2] == 0
    }

    /// Finder ▸ Settings ▸ General ▸ "Show these items on the desktop".
    static func showsVolume(isInternal: Bool, local: Bool, removable: Bool) -> Bool {
        let finder = "com.apple.finder"
        if !local { return pref("ShowMountedServersOnDesktop", in: finder) ?? false }
        if isInternal { return pref("ShowHardDrivesOnDesktop", in: finder) ?? false }
        if removable { return pref("ShowRemovableMediaOnDesktop", in: finder) ?? true }
        return pref("ShowExternalHardDrivesOnDesktop", in: finder) ?? true
    }

    /// Volumes Finder would put on the desktop with the current settings.
    static func desktopVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return showsVolume(isInternal: values?.volumeIsInternal ?? false,
                                   local: values?.volumeIsLocal ?? true,
                                   removable: (values?.volumeIsRemovable ?? false) || (values?.volumeIsEjectable ?? false))
            }
    }

    /// Slides all windows away / back — the Dock's "Show Desktop" (what clicking the wallpaper does).
    static func toggleShowDesktop() {
        typealias SendNotification = @convention(c) (CFString, Int32) -> Void
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDockSendNotification") else { return }
        unsafeBitCast(symbol, to: SendNotification.self)("com.apple.showdesktop.awake" as CFString, 0)
    }

    static func eject(_ volume: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            } catch {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }
}
