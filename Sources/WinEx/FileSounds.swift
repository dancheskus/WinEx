import AppKit

/// Finder's sounds for file operations: moving to the Trash, emptying it, and a short click when
/// a paste (copy or move) is done. Silent when "Play user interface sound effects" is off in
/// System Settings ▸ Sound, like Finder.
@MainActor
enum FileSounds {
    enum Sound {
        case copy, move, trash, delete
    }

    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"
    private static var cache: [String: NSSound] = [:]

    static func play(_ sound: Sound) {
        // "Play user interface sound effects": on unless switched off
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        guard global?["com.apple.sound.uiaudio.enabled"] as? Bool ?? true else { return }
        let file: String
        switch sound {
        case .trash: file = "finder/move to trash.aif"
        case .delete: file = "finder/empty trash.aif"
        case .copy, .move: file = "system/acknowledgment_sent.caf"
        }
        let player = cache[file] ?? NSSound(contentsOfFile: folder + file, byReference: true)
        cache[file] = player
        player?.stop()
        player?.play()
    }
}
