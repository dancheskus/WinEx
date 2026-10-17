import AppKit

/// Finder's «Импортировать с iPhone или iPad» (Continuity Camera): AppKit fills the item with the
/// nearby devices and their actions (take a photo, scan documents, add a sketch); what the device
/// sends comes back on a pasteboard and is saved as a file in the folder the menu was for.
@MainActor
final class DeviceImport: NSObject, @preconcurrency NSServicesMenuRequestor {
    static let shared = DeviceImport()

    /// What a device sends: a scan as PDF, a photo as HEIC or JPEG, a sketch as PNG.
    static let types: [NSPasteboard.PasteboardType] = [.pdf, .init("public.heic"), .init("public.jpeg"), .png, .tiff]

    /// The folder the picture goes into (the one whose menu offered the import).
    private var destination: URL?

    /// Once at launch: AppKit asks for a requestor only for types an app has registered.
    static func register() {
        NSApp.registerServicesMenuSendTypes([], returnTypes: types)
    }

    /// The item for a menu; AppKit hides it when no device is near.
    static func menuItem(into directory: URL) -> NSMenuItem {
        shared.destination = directory
        let item = NSMenuItem(title: L("Импортировать с iPhone или iPad"), action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        item.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        return item
    }

    /// For a responder's `validRequestor(forSendType:returnType:)`: the import, into `directory`,
    /// when the responder has a folder to save into and nothing is being sent.
    static func requestor(into directory: URL?, sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard let directory, sendType == nil, let returnType, types.contains(returnType) else { return nil }
        shared.destination = directory
        return shared
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let directory = destination, let type = pboard.availableType(from: Self.types),
              var data = pboard.data(forType: type) else { return false }
        let ext: String
        let kind: String
        switch type {
        case .pdf: (ext, kind) = ("pdf", L("Скан"))
        case .png: (ext, kind) = ("png", L("Набросок"))
        case .tiff:
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return false }
            data = png
            (ext, kind) = ("png", L("Снимок"))
        default: (ext, kind) = (type.rawValue == "public.heic" ? "heic" : "jpeg", L("Снимок"))
        }
        let url = FileOps.newItemURL(named: "\(kind) \(Self.stamp.string(from: Date())).\(ext)", in: directory)
        return (try? data.write(to: url, options: .withoutOverwriting)) != nil
    }

    /// Like a screenshot's name: «Снимок 2026-10-17 в 14.03.12».
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd '\(L("в"))' HH.mm.ss"
        return formatter
    }()
}
