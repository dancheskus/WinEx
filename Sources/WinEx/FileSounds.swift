import AppKit
import AudioToolbox

/// The system's sounds for file operations: moving to the Trash (the short crumple the Dock plays),
/// emptying it, and a short click when a paste (copy or move) is done. Played as system sound
/// effects — on the alert device, at the alert volume set in System Settings ▸ Sound — and silent
/// when "Play user interface sound effects" is off, like Finder.
@MainActor
enum FileSounds {
    enum Sound {
        case copy, move, trash, delete
    }

    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"
    private static var ids: [String: SystemSoundID] = [:]

    static func play(_ sound: Sound) {
        // "Play user interface sound effects": on unless switched off
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        guard global?["com.apple.sound.uiaudio.enabled"] as? Bool ?? true else { return }
        let file: String
        switch sound {
        case .trash: file = "dock/drag to trash.aif"
        case .delete: file = "finder/empty trash.aif"
        case .copy, .move: file = "system/acknowledgment_sent.caf"
        }
        if ids[file] == nil {
            var id: SystemSoundID = 0
            guard AudioServicesCreateSystemSoundID(URL(fileURLWithPath: folder + file) as CFURL, &id) == noErr else { return }
            ids[file] = id
        }
        if let id = ids[file] { AudioServicesPlaySystemSound(id) }
    }
}
