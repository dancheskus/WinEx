import AppKit

enum Settings {
    private static let defaults = UserDefaults.standard

    static var replaceFinder: Bool {
        get { defaults.bool(forKey: "replaceFinder") }
        set { defaults.set(newValue, forKey: "replaceFinder") }
    }

    static var showHidden: Bool {
        get { defaults.bool(forKey: "showHidden") }
        set { defaults.set(newValue, forKey: "showHidden") }
    }
}

extension Notification.Name {
    static let showHiddenChanged = Notification.Name("WinExShowHiddenChanged")
}

extension URL {
    /// A directory we can browse into (app bundles and other packages are opened instead).
    var isBrowsableDirectory: Bool {
        let values = try? resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
    }

    var displayName: String {
        FileManager.default.displayName(atPath: path)
    }
}

/// One entry of a directory listing.
final class FileItem {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey,
        .localizedTypeDescriptionKey, .fileSizeKey, .localizedNameKey, .tagNamesKey,
    ]

    let url: URL
    let name: String
    let isFolder: Bool
    let modified: Date?
    let typeDescription: String
    let size: Int?
    let tagNames: [String]

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: Set(Self.keys))
        let isDirectory = values?.isDirectory ?? false
        isFolder = isDirectory && !(values?.isPackage ?? false)
        // Localized names for folders ("Загрузки"), real names for files so extensions stay visible
        name = isFolder ? (values?.localizedName ?? url.lastPathComponent) : url.lastPathComponent
        modified = values?.contentModificationDate
        typeDescription = values?.localizedTypeDescription ?? ""
        size = isDirectory ? nil : values?.fileSize
        tagNames = values?.tagNames ?? []
    }

    /// Colors of the item's Finder tags. Each tag is stored as "name\n<color index>" in the
    /// `com.apple.metadata:_kMDItemUserTags` attribute, so renamed/localized/custom tags keep their color.
    lazy var tagColors: [NSColor] = {
        guard !tagNames.isEmpty else { return [] }
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let data: Data? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
            return read > 0 ? buffer : nil
        }
        guard let data, let tags = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        let colors = NSWorkspace.shared.fileLabelColors
        return tags.compactMap { tag in
            guard let index = tag.split(separator: "\n").last.flatMap({ Int($0) }), index > 0, index < colors.count else { return nil }
            return colors[index]
        }
    }()

    lazy var icon: NSImage = NSWorkspace.shared.icon(forFile: url.path)

    var sizeDescription: String? {
        size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}

/// Calls `onChange` whenever the contents of a directory change.
@MainActor
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

enum FileOps {
    /// "name.ext" → "name - копия.ext", "name - копия (2).ext", … until the name is free.
    static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        repeat {
            let suffix = n == 1 ? " - копия" : " - копия (\(n))"
            candidate = directory.appendingPathComponent(base + suffix + (ext.isEmpty ? "" : "." + ext))
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    /// "Новая папка", "Новая папка (2)", … (extension kept: "Новый текстовый документ (2).txt").
    static func newItemURL(named name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : "." + ext))
            n += 1
        }
        return candidate
    }

    static func newFolderURL(in directory: URL) -> URL {
        newItemURL(named: "Новая папка", in: directory)
    }

    /// Moves or copies files into `directory` in the background. Moves into the folder the files
    /// already live in are skipped; name clashes get "- копия" names.
    static func transfer(_ urls: [URL], to directory: URL, copy: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let target = directory.standardizedFileURL.path
            for source in urls {
                let sourcePath = source.standardizedFileURL.path
                do {
                    if target == sourcePath || target.hasPrefix(sourcePath + "/") {
                        throw CocoaError(.fileWriteNoPermission, userInfo: [
                            NSLocalizedDescriptionKey: "Нельзя поместить папку «\(source.lastPathComponent)» в саму себя.",
                        ])
                    }
                    if copy {
                        try fm.copyItem(at: source, to: uniqueDestination(for: source.lastPathComponent, in: directory))
                    } else if source.deletingLastPathComponent().standardizedFileURL.path != target {
                        try fm.moveItem(at: source, to: uniqueDestination(for: source.lastPathComponent, in: directory))
                    }
                } catch {
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
            }
        }
    }

    /// Range to preselect when renaming: the name without its extension, like Explorer.
    static func baseNameRange(of name: String, isFolder: Bool) -> NSRange {
        let ns = name as NSString
        let ext = ns.pathExtension
        guard !isFolder, !ext.isEmpty else { return NSRange(location: 0, length: ns.length) }
        return NSRange(location: 0, length: ns.length - (ext as NSString).length - 1)
    }

    static func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func trash(_ urls: [URL]) {
        // Files may already be gone (e.g. the Dock trashed them after a drag)
        let urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
        }
    }
}

/// Russian plural: plural(5, "элемент", "элемента", "элементов") → "элементов"
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod10 = n % 10, mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return one }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
    return many
}

func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

/// Plain view filled with a (dynamic) color. Uses its own layer: drawing with `NSRect.fill()`
/// (copy compositing) wipes sibling views when AppKit draws several views into one layer.
final class ColorView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
