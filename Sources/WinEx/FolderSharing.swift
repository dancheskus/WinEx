import AppKit

/// A folder shared on the network (SMB), like Explorer's «Общий доступ» and Finder's «Общая папка».
/// macOS keeps the shares itself (`sharing`, the same list as Settings ▸ Общий доступ ▸ Общий
/// доступ к файлам); changing them takes an administrator's password, asked by the system.
enum FolderSharing {
    static let didChange = Notification.Name("WinExFolderSharingChanged")

    struct Share: Equatable {
        var name: String
        var path: String
        var guestAccess: Bool
        var readOnly: Bool
    }

    /// The shares, read from `sharing -l -f json` (no password needed to read).
    static func shares() -> [Share] {
        guard let output = run("/usr/sbin/sharing", ["-l", "-f", "json"]) else { return [] }
        return parse(output)
    }

    static func parse(_ json: Data) -> [Share] {
        guard let list = (try? JSONSerialization.jsonObject(with: json)) as? [String: [String: Any]] else { return [] }
        return list.compactMap { name, values in
            guard let path = values["path"] as? String else { return nil }
            func flag(_ key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
            return Share(name: values["smb_name"] as? String ?? name, path: path,
                         guestAccess: flag("smb_guest_access"), readOnly: flag("smb_read_only"))
        }.sorted { $0.name < $1.name }
    }

    /// The shares that are the user's: existing folders, not other users' home folders (macOS shares
    /// everyone's «Общие» folder by itself).
    static func ownShares(_ shares: [Share], home: String = NSHomeDirectory()) -> [Share] {
        shares.filter { share in
            let path = share.path
            let otherHome = path.hasPrefix("/Users/") && path != home && !path.hasPrefix(home + "/")
            return !otherHome && FileManager.default.fileExists(atPath: path)
        }
    }

    static func share(of folder: URL) -> Share? {
        let path = folder.resolvingSymlinksInPath().path
        return shares().first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path }
    }

    /// «Общий доступ к файлам» is on in System Settings (its SMB server is loaded).
    static var isFileSharingOn: Bool {
        run("/bin/launchctl", ["print", "system/com.apple.smbd"]) != nil
    }

    static let enableArguments = ["/bin/launchctl", "load", "-w", "/System/Library/LaunchDaemons/com.apple.smbd.plist"]

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    // MARK: Changes (as an administrator)

    /// What `sharing` is run with to share `folder` as `name`, or to stop sharing it.
    static func addArguments(_ folder: URL, name: String, guestAccess: Bool) -> [String] {
        ["-a", folder.path, "-S", name, "-s", "001", "-g", guestAccess ? "001" : "000"]
    }

    static func editArguments(_ share: Share) -> [String] {
        ["-e", share.name, "-g", share.guestAccess ? "001" : "000", "-R", share.readOnly ? "1" : "0"]
    }

    /// Shares `folder`; `enablingFileSharing` first turns «Общий доступ к файлам» on, as Finder's
    /// «Включить» does (one password prompt for both).
    @MainActor @discardableResult
    static func add(_ folder: URL, guestAccess: Bool = false, enablingFileSharing: Bool = false) -> Bool {
        let share = ["/usr/sbin/sharing"] + addArguments(folder, name: folder.displayName, guestAccess: guestAccess)
        return changed(admin(enablingFileSharing ? [enableArguments, share] : [share]))
    }

    @MainActor @discardableResult
    static func edit(_ share: Share) -> Bool { changed(admin([["/usr/sbin/sharing"] + editArguments(share)])) }

    @MainActor @discardableResult
    static func remove(_ share: Share) -> Bool { changed(admin([["/usr/sbin/sharing", "-r", share.name]])) }

    private static func changed(_ done: Bool) -> Bool {
        if done { NotificationCenter.default.post(name: didChange, object: nil) }
        return done
    }

    /// Runs commands (tool and arguments each) as root after the system's password prompt, one
    /// after another while they succeed; false if it was cancelled or failed (a failure is shown).
    @MainActor @discardableResult
    static func admin(_ commands: [[String]]) -> Bool {
        let command = adminCommand(commands)
        let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return true }
        // -128: the password prompt was cancelled
        if (error[NSAppleScript.errorNumber] as? Int) != -128 {
            let alert = NSAlert()
            alert.messageText = L("Не удалось изменить общий доступ")
            alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? ""
            alert.runModal()
        }
        return false
    }

    static func adminCommand(_ commands: [[String]]) -> String {
        commands.map { $0.map(shellQuoted).joined(separator: " ") }.joined(separator: " && ")
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A tool's output, or nil when it fails.
    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// Unix permissions as the «Доступ» tab offers them: read and write, read only, none.
enum PermissionLevel: Int, CaseIterable {
    case readWrite, readOnly, none

    var title: String {
        switch self {
        case .readWrite: L("Чтение и запись")
        case .readOnly: L("Только чтение")
        case .none: L("Нет доступа")
        }
    }

    /// The level `bits` (rwx of one class) amount to, or nil for an unusual mix (write only…).
    init?(bits: Int, isFolder: Bool) {
        let read = bits & 4 != 0, write = bits & 2 != 0, run = bits & 1 != 0
        switch (read, write) {
        case (true, true) where !isFolder || run: self = .readWrite
        case (true, false) where !isFolder || run: self = .readOnly
        case (false, false) where !isFolder || !run: self = .none
        default: return nil
        }
    }

    /// New rwx bits: a folder can be opened when it can be read; a file keeps its «run» bit.
    func bits(replacing old: Int, isFolder: Bool) -> Int {
        let run = isFolder ? (self == .none ? 0 : 1) : (self == .none ? 0 : old & 1)
        switch self {
        case .readWrite: return 6 | run
        case .readOnly: return 4 | run
        case .none: return run
        }
    }
}
