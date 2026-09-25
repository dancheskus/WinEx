import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut that opens a WinEx window from any app, like Win+E opens Explorer.
/// Registered with the system (RegisterEventHotKey): no Accessibility permission, no keyboard
/// monitoring, nothing running while waiting.
@MainActor
final class GlobalHotKey {
    enum Preset: String, CaseIterable {
        case off, optionCommandE, controlOptionE, shiftCommandE, commandE

        var title: String {
            switch self {
            case .off: "Выключено"
            case .optionCommandE: "⌥⌘E"
            case .controlOptionE: "⌃⌥E"
            case .shiftCommandE: "⇧⌘E"
            case .commandE: "⌘E — как Win+E"
            }
        }

        fileprivate var modifiers: UInt32 {
            switch self {
            case .off: 0
            case .optionCommandE: UInt32(cmdKey | optionKey)
            case .controlOptionE: UInt32(controlKey | optionKey)
            case .shiftCommandE: UInt32(cmdKey | shiftKey)
            case .commandE: UInt32(cmdKey)
            }
        }
    }

    static let shared = GlobalHotKey()

    static var preset: Preset {
        get { AppDefaults.store.string(forKey: "globalHotKey").flatMap(Preset.init(rawValue:)) ?? .optionCommandE }
        set { AppDefaults.store.set(newValue.rawValue, forKey: "globalHotKey") }
    }

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var isRegistered = false
    /// Registration was tried and refused: another app already owns the shortcut.
    var isTaken: Bool { attempted && !isRegistered && Self.preset != .off }
    private var attempted = false

    /// (Re-)registers the chosen shortcut.
    func apply() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        isRegistered = false
        let preset = Self.preset
        guard preset != .off else { return }
        attempted = true
        installHandler()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_E), preset.modifiers, EventHotKeyID(signature: fourCC("WnEx"), id: 1),
                                         GetApplicationEventTarget(), 0, &reference)
        hotKey = reference
        isRegistered = status == noErr
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.pressed() } }
            return noErr
        }, 1, &type, nil, &handler)
    }

    /// A new window in front, like Win+E.
    private func pressed() {
        AppDelegate.shared.openWindow(at: Settings.startURL)
        NSApp.activate(ignoringOtherApps: true)
    }
}
