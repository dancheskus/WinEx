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

    /// Runs commands (tool and arguments each) as root, one after another while they succeed;
    /// false if it was cancelled or failed (a failure is shown).
    ///
    /// The system's own authorization dialog asks first — Touch ID or the password, as in System
    /// Settings (AppleScript's «with administrator privileges» only takes a password) — and the
    /// permission is kept for a few minutes, so the next change doesn't ask again.
    @MainActor @discardableResult
    static func admin(_ commands: [[String]], prompt: String = L("WinEx хочет изменить общий доступ к папке.")) -> Bool {
        let status = authorize(prompt: prompt)
        if status == errAuthorizationCanceled { return false }
        guard status == errAuthorizationSuccess, let authorization else {
            return failed(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")
        }
        // The tool's exit status comes back as the last line (the call itself doesn't report it)
        let script = "( \(adminCommand(commands)) ) 2>&1; echo \"\(exitMarker)$?\""
        guard let output = executeAsRoot(authorization, "/bin/sh", ["-c", script]) else { return failed("") }
        let (text, exitCode) = parseOutput(output)
        return exitCode == 0 || failed(text)
    }

    static let exitMarker = "winex-exit:"

    /// What a root command printed, and its exit status (nil when the marker line is missing).
    static func parseOutput(_ output: String) -> (text: String, exitCode: Int32?) {
        var lines = output.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let last = lines.last, last.hasPrefix(exitMarker) else { return (output, nil) }
        lines.removeLast()
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), Int32(last.dropFirst(exitMarker.count)))
    }

    @MainActor private static var authorization: AuthorizationRef?

    /// The right to run tools as root: the system dialog (Touch ID or password) unless it's still
    /// granted from a moment ago.
    @MainActor private static func authorize(prompt: String) -> OSStatus {
        if authorization == nil {
            var created: AuthorizationRef?
            let status = AuthorizationCreate(nil, nil, [], &created)
            guard status == errAuthorizationSuccess else { return status }
            authorization = created
        }
        guard let authorization else { return errAuthorizationInternal }
        return kAuthorizationRightExecute.withCString { right in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                prompt.withCString { promptText in
                    var rightItem = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(name: promptKey, valueLength: strlen(promptText),
                                                       value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                    return withUnsafeMutablePointer(to: &rightItem) { rightPointer in
                        withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var rights = AuthorizationRights(count: 1, items: rightPointer)
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            return AuthorizationCopyRights(authorization, &rights, &environment,
                                                           [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                }
            }
        }
    }

    /// AuthorizationExecuteWithPrivileges: deprecated and not in Swift's headers, but still the
    /// system's way to run a tool as root without installing a helper; looked up at run time.
    private typealias ExecuteWithPrivileges = @convention(c) (
        AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus

    /// Everything the tool printed (it has finished then), or nil if it couldn't be started.
    private static func executeAsRoot(_ authorization: AuthorizationRef, _ tool: String, _ arguments: [String]) -> String? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(security, "AuthorizationExecuteWithPrivileges") else { return nil }
        let execute = unsafeBitCast(symbol, to: ExecuteWithPrivileges.self)
        var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pipe: UnsafeMutablePointer<FILE>?
        let status = tool.withCString { path in
            cArguments.withUnsafeBufferPointer { buffer in
                execute(authorization, path, [], buffer.baseAddress!, &pipe)
            }
        }
        guard status == errAuthorizationSuccess, let pipe else { return nil }
        defer { fclose(pipe) }
        let data = FileHandle(fileDescriptor: fileno(pipe), closeOnDealloc: false).readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor private static func failed(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Не удалось изменить общий доступ")
        alert.informativeText = message
        alert.runModal()
        return false
    }

    static func adminCommand(_ commands: [[String]]) -> String {
        commands.map { $0.map(shellQuoted).joined(separator: " ") }.joined(separator: " && ")
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
