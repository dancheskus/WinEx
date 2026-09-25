import AppKit
import UniformTypeIdentifiers

// MARK: - File context menu

/// Actions of the context menu for files, shared by folder windows and the desktop.
@MainActor @objc protocol FileMenuActions {
    func openSelected(_ sender: Any?)
    func quickLook(_ sender: Any?)
    func cut(_ sender: Any?)
    func copy(_ sender: Any?)
    func copyPath(_ sender: Any?)
    func renameSelected(_ sender: Any?)
    func moveToTrash(_ sender: Any?)
    func share(_ sender: Any?)
    func toggleTag(_ sender: NSMenuItem)
    func customizeFolder(_ sender: Any?)
    func showProperties(_ sender: Any?)
    func duplicate(_ sender: Any?)
    func compress(_ sender: Any?)
    func extractArchive(_ sender: Any?)
    func makeAlias(_ sender: Any?)
    func showOriginal(_ sender: Any?)
    func showPackageContents(_ sender: Any?)
    @objc optional func openInNewTab(_ sender: Any?)
    @objc optional func openInNewWindow(_ sender: Any?)
}

@MainActor
enum FileContextMenu {
    /// The Explorer-like menu for right-clicked files: tag colors, Open, Open with, clipboard,
    /// rename / trash / share, tags, folder look, properties.
    static func addItems(to menu: NSMenu, for urls: [URL], target: FileMenuActions, folderTabs: Bool, customizableFolder: Bool) {
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = target
        }
        // Windows 11: the everyday actions as a row of icon buttons on top
        menu.addItem(MenuStyle.actionRow(target: target, actions: [
            ("Вырезать", "scissors", #selector(FileMenuActions.cut(_:))),
            ("Копировать", "doc.on.doc", #selector(FileMenuActions.copy(_:))),
            ("Переим.", "pencil", #selector(FileMenuActions.renameSelected(_:))),
            ("Поделиться", "square.and.arrow.up", #selector(FileMenuActions.share(_:))),
            ("Удалить", "trash", #selector(FileMenuActions.moveToTrash(_:))),
        ]))
        menu.addItem(.separator())
        add("Открыть", #selector(FileMenuActions.openSelected(_:)))
        let single = urls.count == 1 ? urls.first : nil
        // Like Explorer: "Открыть" shows the app the file opens in
        if let single, !single.hasDirectoryPath, let app = NSWorkspace.shared.urlForApplication(toOpen: single) {
            menu.items.last?.image = NSWorkspace.shared.icon(forFile: app.path)
        }
        if let single, FileCommands.isPackage(single) {
            add("Показать содержимое пакета", #selector(FileMenuActions.showPackageContents(_:)))
        }
        if let single, FileCommands.isAlias(single) {
            add("Показать оригинал", #selector(FileMenuActions.showOriginal(_:)))
        }
        if let openWith = OpenWithMenu.item(for: urls) { menu.addItem(openWith) }
        if folderTabs {
            add("Открыть в новой вкладке", #selector(FileMenuActions.openInNewTab(_:)))
            add("Открыть в новом окне", #selector(FileMenuActions.openInNewWindow(_:)))
        }
        if let terminal = TerminalLauncher.menuItem(for: urls) { menu.addItem(terminal) }
        menu.addItem(.separator())
        add("Копировать путь", #selector(FileMenuActions.copyPath(_:)))
        add("Дублировать", #selector(FileMenuActions.duplicate(_:)))
        add("Создать псевдоним", #selector(FileMenuActions.makeAlias(_:)))
        add(single.map { "Сжать «\($0.lastPathComponent)»" } ?? "Сжать \(urls.count) \(plural(urls.count, "объект", "объекта", "объектов"))",
            #selector(FileMenuActions.compress(_:)))
        if let single, FileCommands.isZip(single) {
            add("Распаковать", #selector(FileMenuActions.extractArchive(_:)))
        }
        menu.addItem(.separator())
        // Finder's row of tag colours, then the tags submenu
        menu.addItem(TagRowMenuView.menuItem(for: urls))
        menu.addItem(FileTags.menuItem(for: urls, target: target, action: #selector(FileMenuActions.toggleTag(_:))))
        if customizableFolder { add("Настроить папку…", #selector(FileMenuActions.customizeFolder(_:))) }
        menu.addItem(.separator())
        add("Свойства", #selector(FileMenuActions.showProperties(_:)))
        MenuStyle.decorate(menu)
    }

    /// Body of every `toggleTag(_:)`: applies the tag change a "Теги ▸" item stands for.
    static func toggleTag(_ sender: NSMenuItem) {
        guard let toggle = sender.representedObject as? FileTags.TagToggle else { return }
        FileTags.toggle(toggle.tag, on: toggle.urls, add: toggle.add)
        NotificationCenter.default.post(name: .fileTagsChanged, object: nil)
    }
}

// MARK: - "Открыть с помощью"

/// Builds the "Open with" submenu from the apps LaunchServices knows for the file.
@MainActor
final class OpenWithMenu: NSObject {
    private static let shared = OpenWithMenu()

    private final class Request: NSObject {
        let urls: [URL]
        let app: URL?
        init(urls: [URL], app: URL?) { self.urls = urls; self.app = app }
    }

    /// Apps are taken from the first file; the chosen app opens all of `urls`.
    static func item(for urls: [URL]) -> NSMenuItem? {
        guard let first = urls.first else { return nil }
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: first)
        var seen = Set<String>()
        var apps: [URL] = []
        for app in [defaultApp].compactMap({ $0 }) + workspace.urlsForApplications(toOpen: first) {
            let name = appName(app)
            // Skip duplicates (several copies of one app) and WinEx itself
            guard !seen.contains(name), app.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else { continue }
            seen.insert(name)
            apps.append(app)
        }

        let menu = NSMenu()
        for (index, app) in apps.enumerated() {
            let isDefault = index == 0 && app == defaultApp
            let title = appName(app) + (isDefault ? " (по умолчанию)" : "")
            let item = menu.addItem(withTitle: title, action: #selector(openWith(_:)), keyEquivalent: "")
            item.target = shared
            item.representedObject = Request(urls: urls, app: app)
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if isDefault && apps.count > 1 { menu.addItem(.separator()) }
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        let other = menu.addItem(withTitle: "Выбрать другую программу…", action: #selector(chooseOther(_:)), keyEquivalent: "")
        other.target = shared
        other.representedObject = Request(urls: urls, app: nil)

        let item = NSMenuItem(title: "Открыть с помощью", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Localized app name without ".app" ("Книги", "Visual Studio Code").
    private static func appName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? Request, let app = request.app else { return }
        NSWorkspace.shared.open(request.urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func chooseOther(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? Request else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите программу"
        panel.prompt = "Открыть"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open(request.urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - "Создать"

/// An entry of the "New" submenu (Explorer's ShellNew). Only types some installed app can open are offered.
final class NewItemTemplate: NSObject {
    let title: String
    let fileName: String
    let symbol: String
    private let contentType: UTType?
    private let makeData: (() throws -> Data)?

    private init(_ title: String, fileName: String, symbol: String, type: UTType?, data: (() throws -> Data)?) {
        self.title = title
        self.fileName = fileName
        self.symbol = symbol
        self.contentType = type
        self.makeData = data
    }

    var isFolder: Bool { makeData == nil }

    static let folder = NewItemTemplate("Папку", fileName: "Новая папка", symbol: "folder", type: nil, data: nil)

    static let files: [NewItemTemplate] = [
        NewItemTemplate("Текстовый документ", fileName: "Новый текстовый документ.txt", symbol: "doc.plaintext",
                        type: .plainText, data: { Data() }),
        NewItemTemplate("Документ RTF", fileName: "Новый документ RTF.rtf", symbol: "doc.richtext",
                        type: .rtf, data: { NSAttributedString(string: "").rtf(from: NSRange(location: 0, length: 0), documentAttributes: [:]) ?? Data() }),
        NewItemTemplate("Документ Markdown", fileName: "Новый документ Markdown.md", symbol: "doc.text",
                        type: UTType("net.daringfireball.markdown"), data: { Data() }),
        NewItemTemplate("Документ Microsoft Word", fileName: "Новый документ Microsoft Word.docx", symbol: "doc.richtext.fill",
                        type: UTType("org.openxmlformats.wordprocessingml.document"), data: OfficeFiles.docx),
        NewItemTemplate("Лист Microsoft Excel", fileName: "Новый лист Microsoft Excel.xlsx", symbol: "tablecells",
                        type: UTType("org.openxmlformats.spreadsheetml.sheet"), data: OfficeFiles.xlsx),
        NewItemTemplate("Презентация Microsoft PowerPoint", fileName: "Новая презентация Microsoft PowerPoint.pptx", symbol: "rectangle.on.rectangle",
                        type: UTType("org.openxmlformats.presentationml.presentation"), data: OfficeFiles.pptx),
    ]

    /// File types an installed app can open.
    static var availableFiles: [NewItemTemplate] {
        files.filter { template in
            guard let type = template.contentType else { return true }
            return NSWorkspace.shared.urlForApplication(toOpen: type) != nil
        }
    }

    /// Creates the item with a free name ("… (2)") and returns its URL.
    func create(in directory: URL) throws -> URL {
        let url = FileOps.newItemURL(named: fileName, in: directory)
        if let makeData {
            try makeData().write(to: url, options: .withoutOverwriting)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        return url
    }

    /// "Создать ▸ Папку / — / Текстовый документ / …"; the chosen template is the item's representedObject.
    @MainActor
    static func menuItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let menu = NSMenu()
        func add(_ template: NewItemTemplate) {
            let item = menu.addItem(withTitle: template.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = template
            item.image = NSImage(systemSymbolName: template.symbol, accessibilityDescription: nil)
        }
        add(folder)
        menu.addItem(.separator())
        availableFiles.forEach(add)
        let item = NSMenuItem(title: "Создать", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

// MARK: - Empty Office documents

/// Minimal valid Office Open XML files (Explorer's "New Microsoft Word Document" etc.).
enum OfficeFiles {
    static func docx() throws -> Data {
        try NSAttributedString(string: "").data(
            from: NSRange(location: 0, length: 0),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    static func xlsx() throws -> Data {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        return try zip([
            "[Content_Types].xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="\(contentTypesNS)">\(defaults)\
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
                <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
                <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
                </Types>
                """,
            "_rels/.rels": rels([("rId1", "officeDocument", "xl/workbook.xml")]),
            "xl/workbook.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <workbook xmlns="\(main)" xmlns:r="\(relNS)"><sheets><sheet name="Лист1" sheetId="1" r:id="rId1"/></sheets></workbook>
                """,
            "xl/_rels/workbook.xml.rels": rels([("rId1", "worksheet", "worksheets/sheet1.xml"), ("rId2", "styles", "styles.xml")]),
            "xl/worksheets/sheet1.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <worksheet xmlns="\(main)"><sheetData/></worksheet>
                """,
            "xl/styles.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <styleSheet xmlns="\(main)"><fonts count="1"><font><sz val="12"/><name val="Calibri"/><family val="2"/></font></fonts>\
                <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
                <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
                <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
                <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
                <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
                """,
        ])
    }

    static func pptx() throws -> Data {
        let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="\#(relNS)" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let emptyTree = #"<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"#
        let pml = "application/vnd.openxmlformats-officedocument.presentationml"
        return try zip([
            "[Content_Types].xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="\(contentTypesNS)">\(defaults)\
                <Override PartName="/ppt/presentation.xml" ContentType="\(pml).presentation.main+xml"/>\
                <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="\(pml).slideMaster+xml"/>\
                <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="\(pml).slideLayout+xml"/>\
                <Override PartName="/ppt/slides/slide1.xml" ContentType="\(pml).slide+xml"/>\
                <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
                </Types>
                """,
            "_rels/.rels": rels([("rId1", "officeDocument", "ppt/presentation.xml")]),
            "ppt/presentation.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
                <p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>\
                <p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
                """,
            "ppt/_rels/presentation.xml.rels": rels([
                ("rId1", "slideMaster", "slideMasters/slideMaster1.xml"),
                ("rId2", "slide", "slides/slide1.xml"),
                ("rId3", "theme", "theme/theme1.xml"),
            ]),
            "ppt/slideMasters/slideMaster1.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <p:sldMaster \(ns)>\(emptyTree.replacingOccurrences(of: "<p:cSld>", with: #"<p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>"#))\
                <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
                <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
                """,
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": rels([
                ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
                ("rId2", "theme", "../theme/theme1.xml"),
            ]),
            "ppt/slideLayouts/slideLayout1.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <p:sldLayout \(ns) type="blank" preserve="1">\(emptyTree)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
                """,
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]),
            "ppt/slides/slide1.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <p:sld \(ns)>\(emptyTree)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """,
            "ppt/slides/_rels/slide1.xml.rels": rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]),
            "ppt/theme/theme1.xml": theme,
        ])
    }

    // MARK: Helpers

    private static let contentTypesNS = "http://schemas.openxmlformats.org/package/2006/content-types"
    private static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let defaults = #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>"#

    private static func rels(_ entries: [(id: String, type: String, target: String)]) -> String {
        let body = entries.map { #"<Relationship Id="\#($0.id)" Type="\#(relNS)/\#($0.type)" Target="\#($0.target)"/>"# }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(body)</Relationships>
            """
    }

    /// Office theme with the standard color, font and format schemes (required by PowerPoint).
    private static let theme: String = {
        let colors = [("dk1", #"<a:sysClr val="windowText" lastClr="000000"/>"#), ("lt1", #"<a:sysClr val="window" lastClr="FFFFFF"/>"#),
                      ("dk2", #"<a:srgbClr val="44546A"/>"#), ("lt2", #"<a:srgbClr val="E7E6E6"/>"#),
                      ("accent1", #"<a:srgbClr val="4472C4"/>"#), ("accent2", #"<a:srgbClr val="ED7D31"/>"#),
                      ("accent3", #"<a:srgbClr val="A5A5A5"/>"#), ("accent4", #"<a:srgbClr val="FFC000"/>"#),
                      ("accent5", #"<a:srgbClr val="5B9BD5"/>"#), ("accent6", #"<a:srgbClr val="70AD47"/>"#),
                      ("hlink", #"<a:srgbClr val="0563C1"/>"#), ("folHlink", #"<a:srgbClr val="954F72"/>"#)]
            .map { "<a:\($0.0)>\($0.1)</a:\($0.0)>" }.joined()
        let solid = #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#
        let line = #"<a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>"#
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office"><a:themeElements>\
            <a:clrScheme name="Office">\(colors)</a:clrScheme>\
            <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
            <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
            <a:fmtScheme name="Office"><a:fillStyleLst>\(solid)\(solid)\(solid)</a:fillStyleLst>\
            <a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>\
            <a:effectStyleLst>\(effect)\(effect)\(effect)</a:effectStyleLst>\
            <a:bgFillStyleLst>\(solid)\(solid)\(solid)</a:bgFillStyleLst></a:fmtScheme>\
            </a:themeElements></a:theme>
            """
    }()

    /// Zips the parts with /usr/bin/zip, `[Content_Types].xml` first as Office expects.
    private static func zip(_ parts: [String: String]) throws -> Data {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("WinEx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        for (path, content) in parts {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let archive = folder.appendingPathComponent("out.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        let topLevel = Set(parts.keys.map { String($0.split(separator: "/")[0]) }).subtracting(["[Content_Types].xml"]).sorted()
        process.arguments = ["-X", "-q", "-r", "out.zip", "[Content_Types].xml"] + topLevel
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf: archive)
    }
}

// MARK: - Drag and drop of files

@MainActor
enum FileDrop {
    static func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// What dropping into `directory` would do: move within a volume, copy across volumes or with ⌥,
    /// nothing when the files are already there or a folder would go into itself.
    static func operation(for info: NSDraggingInfo, into directory: URL) -> NSDragOperation {
        let urls = urls(info)
        guard !urls.isEmpty else { return [] }
        let target = directory.standardizedFileURL.path
        if urls.contains(where: { let path = $0.standardizedFileURL.path; return target == path || target.hasPrefix(path + "/") }) {
            return []
        }
        let mask = info.draggingSourceOperationMask
        let modifiers = NSEvent.modifierFlags.intersection([.command, .option])
        // ⌘⌥: an alias (Alt+drag makes a shortcut in Explorer)
        if modifiers == [.command, .option] { return mask.contains(.link) ? .link : [] }
        // ⌘: move even to another disk (Shift+drag in Explorer)
        if modifiers == .command, mask.contains(.move) {
            return urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == target }) ? [] : .move
        }
        if modifiers.contains(.option) || !sameVolume(urls[0], directory) {
            return mask.contains(.copy) ? .copy : []
        }
        if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == target }) { return [] }
        if mask.contains(.move) { return .move }
        if mask.contains(.generic) { return .generic }
        return mask.contains(.copy) ? .copy : []
    }

    static func perform(_ info: NSDraggingInfo, into directory: URL) -> Bool {
        let operation = operation(for: info, into: directory)
        guard operation != [] else { return false }
        if operation == .link {
            FileCommands.makeAliases(urls(info), in: directory)
            return true
        }
        FileOps.transfer(urls(info), to: directory, copy: operation == .copy)
        return true
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let volumeA = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let volumeB = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        guard let volumeA, let volumeB else { return true }
        return volumeA.isEqual(volumeB)
    }
}
