import AppKit
import UniformTypeIdentifiers

/// Settings ▸ Основные ▸ Настройки: save every WinEx setting to a file, load them back, or go
/// back to the defaults. Loading and resetting restart WinEx with the same windows.
@MainActor
enum SettingsBackup {
    private static let fileExtension = "winexsettings"
    private static let marker = "WinExSettings"

    /// Never saved or loaded: the restart hand-over, and AppKit's own bookkeeping.
    private static func isInternal(_ key: String) -> Bool {
        key == "restartSession" || key.hasPrefix("NS") || key.hasPrefix("com.apple")
    }

    /// Kept when loading or resetting: switching "instead of Finder" through a restart could
    /// leave the Mac without a desktop — it's switched in Settings ▸ Finder.
    private static let keptOnLoad: Set<String> = ["replaceFinder"]
    /// Kept by "Восстановить по умолчанию": the user's arrangement of the desktop icons, where
    /// the last window was, and the Finder mode.
    private static let keptOnReset: Set<String> = ["replaceFinder", "desktopLayout", "lastWindowPlacement"]

    private static var settings: [String: Any] {
        (AppDefaults.store.persistentDomain(forName: AppDefaults.domainName) ?? [:]).filter { !isInternal($0.key) }
    }

    // MARK: Save

    static func save(from window: NSWindow?) {
        let panel = NSSavePanel()
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "WinEx \(date.string(from: Date())).\(fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .propertyList]
        panel.message = L("Все настройки WinEx: вид, боковое меню, теги, программы, рабочий стол…")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try fileData().write(to: url, options: .atomic)
        } catch {
            show(error, in: window)
        }
    }

    /// The settings file's contents.
    static func fileData() throws -> Data {
        let file: [String: Any] = [marker: 1, "version": Updater.shared.currentVersion, "date": Date(), "settings": settings]
        return try PropertyListSerialization.data(fromPropertyList: file, format: .xml, options: 0)
    }

    /// A settings file's settings and date (nil: not a WinEx settings file).
    static func read(_ data: Data) -> (settings: [String: Any], date: Date?)? {
        guard let file = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              file[marker] != nil, let saved = file["settings"] as? [String: Any] else { return nil }
        return (saved, file["date"] as? Date)
    }

    // MARK: Load

    static func load(into window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .propertyList, .propertyList]
        panel.message = L("Файл настроек WinEx")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let (saved, savedDate) = read(data) else {
            let alert = NSAlert()
            alert.messageText = L("Это не файл настроек WinEx")
            alert.informativeText = url.lastPathComponent
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Загрузить настройки из «%@»?", url.lastPathComponent)
        var details = L("Текущие настройки будут заменены. WinEx перезапустится с теми же окнами.")
        if let date = savedDate { details = L("Сохранены %@.", FileDetails.longDate(date)) + " " + details }
        alert.informativeText = details
        alert.addButton(withTitle: L("Загрузить"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apply(saved)
        AppDelegate.shared.restartKeepingWindows(settingsOpen: true)
    }

    /// Replaces the settings with `saved` (without the restart; scenario runs check this).
    static func apply(_ saved: [String: Any]) {
        let store = AppDefaults.store
        for key in settings.keys where !keptOnLoad.contains(key) { store.removeObject(forKey: key) }
        for (key, value) in saved where !isInternal(key) && !keptOnLoad.contains(key) { store.set(value, forKey: key) }
    }

    // MARK: Reset

    static func resetToDefaults(in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = L("Восстановить настройки по умолчанию?")
        alert.informativeText = L("Все настройки WinEx вернутся к исходным: вид папок, столбцы, боковое меню, теги, программы, язык, клавиши. Расстановка значков на рабочем столе и режим «вместо Finder» останутся. WinEx перезапустится.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Восстановить"))
        alert.addButton(withTitle: L("Отмена"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        reset()
        AppDelegate.shared.restartKeepingWindows(settingsOpen: true)
    }

    /// Removes every setting except the kept ones (without the restart).
    static func reset() {
        for key in settings.keys where !keptOnReset.contains(key) { AppDefaults.store.removeObject(forKey: key) }
    }

    private static func show(_ error: Error, in window: NSWindow?) {
        if let window { NSAlert(error: error).beginSheetModal(for: window) } else { NSAlert(error: error).runModal() }
    }
}
