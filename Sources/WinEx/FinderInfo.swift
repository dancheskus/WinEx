import AppKit

/// What Finder's «Свойства» keeps besides the file system's own attributes: the «Шаблон» flag and
/// the Finder comment.
enum FinderInfo {
    // MARK: «Шаблон» (stationery pad)

    private static let finderInfo = "com.apple.FinderInfo"
    /// kIsStationery in the Finder flags (bytes 8–9 of FinderInfo, big-endian).
    private static let stationeryFlag: UInt16 = 0x0800

    /// A stationery pad: opening it makes a copy to work on, the original stays as it is.
    static func isStationery(_ url: URL) -> Bool {
        guard let info = attribute(finderInfo, of: url), info.count >= 10 else { return false }
        return (UInt16(info[8]) << 8 | UInt16(info[9])) & stationeryFlag != 0
    }

    static func setStationery(_ on: Bool, on url: URL) throws {
        var info = [UInt8](attribute(finderInfo, of: url) ?? Data(count: 32))
        if info.count < 32 { info += [UInt8](repeating: 0, count: 32 - info.count) }
        var flags = UInt16(info[8]) << 8 | UInt16(info[9])
        if on { flags |= stationeryFlag } else { flags &= ~stationeryFlag }
        info[8] = UInt8(flags >> 8)
        info[9] = UInt8(flags & 0xFF)
        if info.allSatisfy({ $0 == 0 }) {
            removeAttribute(finderInfo, of: url)
        } else {
            try setAttribute(finderInfo, Data(info), of: url)
        }
    }

    // MARK: Comments

    private static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    /// The Finder comment: Finder's own copy in the folder's .DS_Store first (what its «Свойства»
    /// show), else the one Spotlight reads.
    static func comment(of url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        if let store = DSStore(folder: folder), case .string(let text)? = store.records[url.lastPathComponent]?["cmmt"] {
            return text
        }
        if let data = attribute(commentAttribute, of: url),
           let text = try? PropertyListSerialization.propertyList(from: data, format: nil) as? String {
            return text
        }
        return ""
    }

    /// Kept where Spotlight reads it, and — when Finder runs — handed to Finder too, so its
    /// «Свойства» show the same (it keeps comments in .DS_Store, which only it writes).
    static func setComment(_ text: String, on url: URL, tellFinder: Bool = true) {
        if text.isEmpty {
            removeAttribute(commentAttribute, of: url)
        } else if let data = try? PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0) {
            try? setAttribute(commentAttribute, data, of: url)
        }
        #if DEBUG
        // Scenarios never drive the user's Finder (it would ask for permission on their screen)
        if Scenario.isRequested { return }
        #endif
        guard tellFinder, NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first != nil else { return }
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "tell application \"Finder\" to set comment of (POSIX file \(quoted(url.path)) as alias) to \(quoted(text))"
        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    // MARK: Extended attributes

    private static func attribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? data : nil
        }
    }

    private static func setAttribute(_ name: String, _ data: Data, of url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private static func removeAttribute(_ name: String, of url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            removexattr(path, name, 0)
        }
    }
}
