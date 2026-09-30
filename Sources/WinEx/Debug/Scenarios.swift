#if DEBUG
import AppKit
import AVFoundation

/// Regression scenarios for `scripts/run-scenario.sh <name>`.
@MainActor
enum Scenarios {
    static let all: [String: (Scenario) -> Void] = [
        "undo": undo,
        "newfolder": newFolder,
        "slowclick": slowClick,
        "perf": perf,
        "hittest": hitTest,
        "desktop": desktop,
        "placement": placement,
        "desktopreset": desktopReset,
        "placement2": placementSecondScreen,
        "mousedrag": mouseDrag,
        "monitorgone": monitorGone,
        "fileops": fileOps,
        "search": search,
        "filecommands": fileCommands,
        "drives": drives,
        "trashaccess": trashAccess,
        "update": update,
        "settings": settingsTabs,
        "sidebar": sidebar,
        "commandbar": commandBarScenario,
        "menuswitch": menuSwitch,
        "properties": properties,
        "terminal": terminalMenu,
        "session": session,
        "apps": appsSettings,
        "backup": backup,
        "tabmerge": tabMerge,
        "wizard": wizard,
        "shell": shell,
        "fences": fences,
        "portal": portal,
        "look": look,
        "addressclick": addressClick,
        "breadcrumbs": breadcrumbs,
        "contextmenu": contextMenu,
        "unzip": unzip,
        "paste": pasteKeys,
        "keys": keyboardShortcuts,
        "threecopies": threeCopies,
        "dragpreview": dragPreview,
        "replaylayout": replayLayout,
        "finderbutton": finderButton,
        "tagwatch": tagWatch,
        "foldericon": folderIcon,
        "video": video,
        "selfupdate": selfUpdate,
        "updated": updated,
    ]

    /// A video in icon view: its preview, its length under the name, the play button on hover, and
    /// playing in place; in the details view a small preview instead of the file type's icon.
    static func video(_ s: Scenario) {
        let folder = s.makeFiles(["notes.txt"], in: "videos")
        let clip = folder.appendingPathComponent("clip.mov")
        makeClip(at: clip, seconds: 3)
        s.window?.navigate(to: folder)
        func grid() -> FileCollectionView? {
            func find(_ view: NSView) -> FileCollectionView? { (view as? FileCollectionView) ?? view.subviews.lazy.compactMap(find).first }
            return s.window?.window?.contentView.flatMap(find)
        }
        func clipItem() -> FileGridItem? {
            guard let grid = grid() else { return nil }
            return (0..<grid.numberOfItems(inSection: 0)).lazy.compactMap { grid.item(at: IndexPath(item: $0, section: 0)) as? FileGridItem }
                .first { $0.textField?.stringValue.hasSuffix("clip.mov") == true }
        }
        func shot(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let number = s.window?.window?.windowNumber {
                    try? "\(number)".write(to: s.output.appendingPathComponent("tab-\(n)"), atomically: true, encoding: .utf8)
                }
            }
        }
        s.run([
            (1.0, "icons", { s.setViewMode(.largeIcons) }),
            (1.5, "hover", {
                guard let item = clipItem(), let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                                                windowNumber: s.window?.window?.windowNumber ?? 0, context: nil,
                                                                                eventNumber: 0, trackingNumber: 0, userData: nil) else { s.note("  (no clip item: \(s.names()), grid \(grid() != nil), file \(FileManager.default.fileExists(atPath: clip.path)))"); return }
                item.mouseEntered(with: event)
                shot(0)
            }),
            (1.0, "play", {
                guard let item = clipItem() else { return }
                let button = item.view.subviews.first { $0 is VideoPlayButton }
                let center = button.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
                s.note("  play button shown: \(button?.isHidden == false); click plays: \(item.handlePlayClick(at: center))  expect true, true")
            }),
            (1.2, "playing", {
                guard let item = clipItem() else { return }
                let video = item.view.subviews.first { $0 is InlineVideoView } as? InlineVideoView
                s.note("  playing in place: \(video != nil), at \(String(format: "%.1f", video?.player.currentTime().seconds ?? 0)) s  expect true, > 0")
                shot(1)
            }),
            (1.0, "details", { s.setViewMode(.details) }),
            (1.5, "details shot", { shot(2) }),
            (1.0, "done", {}),
        ])
    }

    /// A short video: coloured frames, `seconds` long.
    private static func makeClip(at url: URL, seconds: Int) {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let size = CGSize(width: 320, height: 180)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 10
        for frame in 0..<(seconds * fps) {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                context.setFillColor(NSColor.systemOrange.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                context.setFillColor(NSColor.systemBlue.cgColor)
                context.fill(CGRect(x: CGFloat(frame) * 8, y: 40, width: 80, height: 100))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }

    /// Customized folder icons (symbol, emoji, tag colors) as pictures, and the customization popover.
    static func folderIcon(_ s: Scenario) {
        let samples: [(Int?, FolderCustomization?)] = [(nil, .symbol("person.crop.circle")), (5, .symbol("person.crop.circle")),
                                                       (2, .symbol("star.fill")), (nil, .emoji("🐱")), (6, nil), (nil, nil)]
        let sheet = NSImage(size: NSSize(width: 160 * CGFloat(samples.count), height: 160), flipped: false) { _ in
            for (n, sample) in samples.enumerated() {
                FolderIcon.render(tagColor: sample.0, customization: sample.1, filled: n % 2 == 0).draw(in: NSRect(x: CGFloat(n) * 160, y: 0, width: 160, height: 160))
            }
            return true
        }
        if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: s.output.appendingPathComponent("icons.png"))
        }
        // The popover, on a folder with one tag and a symbol
        let folder = s.makeFiles(["Папка/", "alicorn-ui/", "dynamic_list/", "TorrServerMacInstaller/", "WinEx/",
                                  "План действий для поездки.docx"], in: "custom").appendingPathComponent("Папка")
        try? FileTags.setTags([FileTags.Tag(name: "Желтый", color: 5)], on: folder)
        try? FolderCustomization.write(.symbol("person.crop.circle"), to: folder)
        s.window?.navigate(to: folder.deletingLastPathComponent())
        s.run([
            (1.0, "grid", {
                // The icon grid (medium icons, one selected) for comparing with Finder's
                s.setViewMode(.mediumIcons)
                s.select("WinEx")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let number = s.window?.window?.windowNumber {
                        try? "\(number)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                    }
                }
            }),
            (1.2, "rename", {
                // Finder's rename frame: just around the name, two lines for a long one
                s.select("TorrServerMacInstaller")
                s.send("renameSelected:")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let number = s.window?.window?.windowNumber {
                        try? "\(number)".write(to: s.output.appendingPathComponent("tab-1"), atomically: true, encoding: .utf8)
                    }
                }
            }),
            (1.5, "end rename", { s.window?.window?.makeFirstResponder(nil) }),
            (1.0, "popover", {
                guard let view = s.window?.window?.contentView else { return }
                FolderCustomizationController.show(for: folder, relativeTo: NSRect(x: 300, y: 300, width: 10, height: 10), of: view)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let popover = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("Popover") }) else { return }
                    // A click on a circle at the right: the row must stay where it is
                    func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
                    let circles = buttons(popover.contentView ?? NSView()).filter { $0.identifier != nil && $0.frame.width == 26 }
                    let before = circles.first.map { $0.convert($0.bounds, to: nil).minX } ?? 0
                    circles.dropLast().last?.performClick(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let after = buttons(popover.contentView ?? NSView()).filter { $0.identifier != nil && $0.frame.width == 26 }
                            .first.map { $0.convert($0.bounds, to: nil).minX } ?? 0
                        s.note((abs(after - before) < 0.5 ? "ok" : "FAIL") + " tag circles after a click: \(before) → \(after)")
                        try? "\(popover.windowNumber)".write(to: s.output.appendingPathComponent("tab-2"), atomically: true, encoding: .utf8)
                    }
                }
            }),
            (4.0, "done", {}),
        ])
    }

    /// A tag put on a file by another app (here: the xattr tool) shows in WinEx at once.
    static func tagWatch(_ s: Scenario) {
        let folder = s.makeFiles(["a.txt"], in: "tags")
        s.window?.navigate(to: folder)
        s.setViewMode(.details)
        s.run([
            (1.0, "tagged from outside", {
                let data = (try? PropertyListSerialization.data(fromPropertyList: ["Зеленый\n2", "Желтый\n5"], format: .binary, options: 0)) ?? Data()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                process.arguments = ["-wx", "com.apple.metadata:_kMDItemUserTags", data.map { String(format: "%02x", $0) }.joined(), folder.appendingPathComponent("a.txt").path]
                try? process.run(); process.waitUntilExit()
            }),
            (1.5, "shown", {
                s.note("  a.txt shows: \(s.window?.debugShownTags["a.txt"] ?? [])  expect [Зеленый, Желтый]")
                s.send("refresh:")
            }),
            (1.0, "a folder with four tags (the last one added: yellow)", {
                let dir = folder.appendingPathComponent("Папка")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? FileTags.setTags([FileTags.Tag(name: "Зеленый", color: 2), FileTags.Tag(name: "Красный", color: 6),
                                       FileTags.Tag(name: "Синий", color: 4), FileTags.Tag(name: "Желтый", color: 5)], on: dir)
                s.setViewMode(.largeIcons)
                s.send("refresh:")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let window = s.window?.window { try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8) }
                }
            }),
            (3.0, "done", {}),
        ])
    }

    /// Finder's "Open in WinEx" button, made in the sandbox (not run: it would control Finder).
    static func finderButton(_ s: Scenario) {
        let app = ProcessInfo.processInfo.environment["WINEX_BUTTON_AT"].map { URL(fileURLWithPath: $0) } ?? s.sandbox.appendingPathComponent("Open in WinEx.app")
        do {
            try FinderToolbarButton.install(at: app)
            let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            let icon = FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/applet.icns").path)
            let verify = Process()
            verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verify.arguments = ["--verify", "--deep", "--strict", app.path]
            try verify.run(); verify.waitUntilExit()
            let decompile = Process(), out = Pipe()
            decompile.executableURL = URL(fileURLWithPath: "/usr/bin/osadecompile")
            decompile.arguments = [app.appendingPathComponent("Contents/Resources/Scripts/main.scpt").path]
            decompile.standardOutput = out
            try decompile.run(); decompile.waitUntilExit()
            let script = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            s.note("  built: no Dock icon \(plist?["LSUIElement"] as? Bool == true), asks for Finder \(plist?["NSAppleEventsUsageDescription"] != nil), WinEx icon \(icon && plist?["CFBundleIconName"] == nil && !FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/Assets.car").path)), signed \(verify.terminationStatus == 0), opens WinEx \(script.contains("open -b \(Bundle.main.bundleIdentifier ?? "")"))  expect true ×5")
        } catch {
            s.note("  FAIL: \(error.localizedDescription)")
        }
        // What the button sends: two files of one folder → one window, both selected
        let folder = s.makeFiles(["a.txt", "b.txt", "c.txt"], in: "sel")
        AppDelegate.shared.windowControllers.forEach { $0.window?.close() }
        let before = AppDelegate.shared.windowControllers.count
        AppDelegate.shared.application(NSApp, open: [folder.appendingPathComponent("a.txt"), folder.appendingPathComponent("c.txt")])
        s.run([
            (1.5, "opened", {
                let new = AppDelegate.shared.windowControllers.count - before
                s.note("  windows opened: \(new), in \(AppDelegate.shared.windowControllers.last?.selectedTab.url.lastPathComponent ?? "-"), selected \(s.selectedNames.sorted())  expect 1, sel, [a.txt, c.txt]")
            }),
        ])
    }

    /// A copy of a real desktop arrangement (WINEX_LAYOUT_FILE, the JSON of "desktopLayout") shown
    /// on the monitors connected now, in the scenario's own settings; the main desktop is photographed.
    static func replayLayout(_ s: Scenario) {
        guard let path = ProcessInfo.processInfo.environment["WINEX_LAYOUT_FILE"], let data = FileManager.default.contents(atPath: path) else {
            s.note("  (no WINEX_LAYOUT_FILE)"); return s.run([])
        }
        // (The scenario's own settings get their arrangement back afterwards)
        let before = AppDefaults.store.data(forKey: "desktopLayout")
        AppDefaults.store.set(data, forKey: "desktopLayout")
        let controller = DesktopController()
        controller.show()
        s.run([
            (2.0, "shown", {
                guard let view = NSApp.windows.compactMap({ $0.contentView as? DesktopView }).first(where: { $0.window?.screen == NSScreen.screens.first }),
                      let window = view.window, let size = window.screen?.frame.size else { return }
                for fence in view.layout.fences {
                    let frame = view.debugFenceView(fence.id)?.frame ?? .zero
                    s.note("  «\(fence.title)» at \(Int(frame.minX)),\(Int(frame.minY)): \(Int(size.width - frame.maxX)) pt from the right edge")
                }
                if let select = ProcessInfo.processInfo.environment["WINEX_SELECT"] {
                    for v in NSApp.windows.compactMap({ $0.contentView as? DesktopView }) { v.debugSelect(select.components(separatedBy: "|")); v.displayIfNeeded() }
                }
                let shown = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                    .filter { name in !name.hasPrefix(".") && !view.layout.fences.contains { $0.members.contains(name) } && view.debugCenter(of: name) != nil }
                s.note("  icons in grid cells: \(shown.filter(view.debugOnGrid).count) of \(shown.count)  (grid on: \(view.layout.alignToGrid))")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                // The same arrangement moved to another size (WINEX_TARGET_SIZE, e.g. 1710x1107)
                if let target = ProcessInfo.processInfo.environment["WINEX_TARGET_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), target.count == 2 {
                    let to = CGSize(width: target[0], height: target[1])
                    let names = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                        .filter { name in !name.hasPrefix(".") && !view.layout.fences.contains { $0.members.contains(name) } && view.debugCenter(of: name) != nil }
                    let iconRects = names.compactMap { view.debugCenter(of: $0).map { DesktopLayout.cell(around: $0) } }
                    let fenceRects = view.layout.fences.compactMap { view.debugFenceView($0.id)?.frame }
                    let offsets = ScreenAnchoring.offsets(for: iconRects + fenceRects, from: size, to: to)
                    s.note("  on \(Int(to.width))×\(Int(to.height)):")
                    for (n, name) in names.enumerated() {
                        let r = iconRects[n].offsetBy(dx: offsets[n].dx, dy: offsets[n].dy)
                        s.note("    \(name): centre \(Int(r.midX)),\(Int(r.midY))  (right edge \(Int(to.width - r.maxX)), bottom \(Int(to.height - r.maxY)))")
                    }
                    for (k, fence) in view.layout.fences.enumerated() where k < fenceRects.count {
                        let r = fenceRects[k].offsetBy(dx: offsets[names.count + k].dx, dy: offsets[names.count + k].dy)
                        s.note("    «\(fence.title)»: \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))  (right edge \(Int(to.width - r.maxX)))")
                    }
                }
            }),
            (2.0, "done", {
                controller.hide()
                if let before { AppDefaults.store.set(before, forKey: "desktopLayout") } else { AppDefaults.store.removeObject(forKey: "desktopLayout") }
            }),
        ])
    }

    /// Dragging from a window in icon view: the drag shows the preview, where the icon is drawn.
    static func dragPreview(_ s: Scenario) {
        let base = s.makeFiles([], in: "pics")
        // A wide picture: its preview isn't square, unlike the file type's icon
        let picture = base.appendingPathComponent("wide.png")
        let image = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill()
            NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 200, height: 200).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: picture)
        }
        s.window?.navigate(to: base)
        s.setViewMode(.largeIcons)
        s.run([
            (2.0, "drag it", {
                guard let grid = s.grid, let items = grid.draggingItems?([0]), let item = items.first else { s.note("  (no drag)"); return }
                let contents = item.imageComponents?.first?.contents as? NSImage
                let shown = (grid.item(at: IndexPath(item: 0, section: 0)) as? FileGridItem)?.imageView
                let shownImage = shown?.image
                s.note("  drag image: \(Int(contents?.size.width ?? 0))×\(Int(contents?.size.height ?? 0)), same as shown: \(contents === shownImage)  expect the preview shown (true)")
                if let shown {
                    let box = shown.convert(shown.bounds, to: grid)
                    s.note("  frame \(item.draggingFrame.integral) inside the icon's \(box.integral): \(box.insetBy(dx: -1, dy: -1).contains(item.draggingFrame))  expect true")
                }
            }),
        ])
    }

    /// Three copies at once: how their windows look and sit, and cancelling the middle one alone.
    static func threeCopies(_ s: Scenario) {
        let fm = FileManager.default
        let from = s.makeFiles([], in: "from")
        let names = ["Видео.mov", "Архив.zip", "Образ.dmg"]
        for name in names {
            let url = from.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) {
                let chunk = Data(repeating: 0x5A, count: 8 << 20)
                for _ in 0..<15 { handle.write(chunk) }  // 120 MB
                try? handle.close()
            }
        }
        let targets = (1...3).map { s.makeFiles([], in: "to\($0)") }
        FileOperation.cloneFiles = false
        FileOperation.slowDownForTesting = 0.12
        func progressWindows() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && $0.windowController is FileOperationWindowController }.sorted { $0.windowNumber < $1.windowNumber }
        }
        s.run([
            (0.5, "start three copies, a moment apart", {
                for (n, name) in names.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.4) {
                        FileOperations.start(.copy, [from.appendingPathComponent(name)], to: targets[n])
                    }
                }
            }),
            (2.5, "the window", {
                let windows = progressWindows()
                s.note("  progress windows: \(windows.count)  expect 1")
                guard let window = windows.first, let content = window.contentView else { return }
                let cancels = s.findAll(NSButton.self, in: content).filter { $0.toolTip == L("Отмена") }
                s.note("  «\(window.title)», \(Int(window.frame.width))×\(Int(window.frame.height)), cancel buttons: \(cancels.count)  expect «Выполняется 3 операции», 3")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
            }),
            (1.5, "fewer details", {
                guard let window = progressWindows().first, let content = window.contentView else { return }
                s.findAll(NSButton.self, in: content).first { $0.title == L("Меньше подробностей") }?.performClick(nil)
                s.note("  \(Int(window.frame.width))×\(Int(window.frame.height))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-1"), atomically: true, encoding: .utf8)
                }
            }),
            (1.5, "cancel the second one", {
                guard let window = progressWindows().first, let content = window.contentView else { s.note("  (no window)"); return }
                let cancels = s.findAll(NSButton.self, in: content).filter { $0.toolTip == L("Отмена") }
                    .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
                guard cancels.count >= 2 else { s.note("  (\(cancels.count) cancel buttons)"); return }
                cancels[1].performClick(nil)
            }),
            (1.5, "right after", {
                guard let window = progressWindows().first, let content = window.contentView else { s.note("  (no window)"); return }
                let cancels = s.findAll(NSButton.self, in: content).filter { $0.toolTip == L("Отмена") }
                s.note("  «\(window.title)», blocks left: \(cancels.count)  expect «Выполняется 2 операции», 2")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-2"), atomically: true, encoding: .utf8)
                s.findAll(NSButton.self, in: content).first { $0.title == L("Больше подробностей") }?.performClick(nil)
            }),
            (25.0, "when the others are done", {
                for (n, target) in targets.enumerated() {
                    let size = (try? fm.attributesOfItem(atPath: target.appendingPathComponent(names[n]).path)[.size] as? Int) ?? nil
                    s.note("  \(names[n]): \(size.map { "\($0 >> 20) MB" } ?? "no file")  expect \(n == 1 ? "no file (cancelled)" : "120 MB")")
                }
                s.note("  windows left: \(progressWindows().count)  expect 0")
                FileOperation.slowDownForTesting = 0
                FileOperation.cloneFiles = true
            }),
        ])
    }

    /// Every shortcut of Settings ▸ Клавиатура, in both modes, as a real keyboard sends it (arrows and
    /// F-keys with their function / numeric-pad flags), through the application like real key
    /// presses. Full screen and refresh are counted rather than done.
    static func keyboardShortcuts(_ s: Scenario) {
        let base = s.makeFiles(["Папка/", "file.txt", "del.txt", "gone.txt"])
        s.makeFiles(["Внутри/"], in: "Папка")
        let folder = base.appendingPathComponent("Папка")
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        func press(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], ignoring: String? = nil) {
            var flags = modifiers
            let scalar = characters.unicodeScalars.first.map { Int($0.value) } ?? 0
            if (0xF700...0xF703).contains(scalar) { flags.formUnion([.function, .numericPad]) }       // arrows
            if (0xF704...0xF8FF).contains(scalar) { flags.insert(.function) }                         // F-keys, ⌦
            guard let window = s.window?.window,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code) else { return }
            NSApp.sendEvent(event)
        }
        func fn(_ key: Int) -> String { String(Character(UnicodeScalar(key) ?? " ")) }
        let down = fn(NSDownArrowFunctionKey), up = fn(NSUpArrowFunctionKey), left = fn(NSLeftArrowFunctionKey), right = fn(NSRightArrowFunctionKey)
        let f2 = fn(NSF2FunctionKey), f3 = fn(NSF3FunctionKey), f4 = fn(NSF4FunctionKey), f5 = fn(NSF5FunctionKey)
        let f10 = fn(NSF10FunctionKey), forwardDelete = fn(NSDeleteFunctionKey)
        var here: String { s.window?.selectedTab.url.lastPathComponent ?? "?" }
        var focus: String {
            let responder = s.window?.window?.firstResponder
            if let editor = responder as? NSTextView {
                if editor.delegate is RoomySearchField { return "search" }
                if editor.delegate is AddressField { return "address" }
                return "rename"
            }
            return "list"
        }
        func reset(in url: URL = base) {
            press("\u{1b}", 53)  // Esc: ends whatever is being typed
            s.window?.navigate(to: url)
        }
        func check(_ title: String, _ result: @escaping @autoclosure () -> String, _ expected: String, after: Double = 0.4) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                let got = result()
                s.note("  \(got == expected ? "ok  " : "FAIL") \(title): \(got)  expect \(expected)")
            }
        }
        func mode(_ windows: Bool) -> Scenario.Step {
            (0.5, windows ? "— Как в Windows —" : "— Как в Finder —", {
                Settings.windowsKeys = windows
                NotificationCenter.default.post(name: .keyboardSettingsChanged, object: nil)
                reset()
            })
        }
        // A keypress test: get ready (navigate), then select, press and look
        func test(_ title: String, in url: URL = base, select name: String? = nil, _ action: @escaping () -> Void,
                  _ result: @escaping () -> String, _ expected: String) -> [Scenario.Step] {
            [(0.7, "", { reset(in: url) }),
             (0.8, title, {
                 if let name { s.select(name) } else { s.window?.window?.makeFirstResponder(s.table) }
                 action()
                 check(title, result(), expected)
             })]
        }
        func counted(_ title: String, _ counter: @escaping () -> Int, _ action: @escaping () -> Void) -> [Scenario.Step] {
            var before = 0
            return [(0.7, "", { reset() }),
                    (0.8, title, { before = counter(); s.window?.window?.makeFirstResponder(s.table); action(); check(title, counter() - before == 1 ? "done" : "not done", "done") })]
        }
        func trash(_ title: String, _ action: @escaping () -> Void) -> [Scenario.Step] {
            [(0.7, "", { reset() }),
             (0.8, title, { s.select("del.txt"); action(); check(title, s.files().contains("del.txt") ? "still there" : "in the Trash", "in the Trash", after: 1.2) }),
             (1.6, "⌘Z (back from the Trash)", { s.key("z", code: 6, modifiers: .command, viaMenu: true); FileUndo.waitForFileWork() }),
             (0.8, "", { check("undo", s.files().contains("del.txt") ? "back" : "missing", "back", after: 0) })]
        }
        func properties(_ title: String, _ action: @escaping () -> Void) -> [Scenario.Step] {
            [(1.0, "", { reset() }),
             (0.8, title, {
                 s.select("file.txt")
                 action()
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                     let window = NSApp.windows.first { $0.isVisible && $0.windowController is PropertiesWindowController }
                     s.note("  \(window != nil ? "ok  " : "FAIL") \(title): \(window != nil ? "Свойства open" : "nothing")  expect Свойства open")
                     window?.close()
                 }
             })]
        }
        let refreshes = { ExplorerWindowController.debugRefreshes }
        let fullScreens = { ExplorerWindowController.debugFullScreenToggles }

        var steps: [Scenario.Step] = [(0.8, "start", {})]
        // Finder
        steps.append(mode(false))
        steps += test("⌘↓ opens", select: "Папка", { press(down, 125, .command) }, { here }, "Папка")
        steps += test("⌘O opens", select: "Папка", { press("o", 31, .command) }, { here }, "Папка")
        steps += test("Enter renames", select: "file.txt", { press("\r", 36) }, { focus }, "rename")
        steps += test("F2 does nothing", select: "file.txt", { press(f2, 120) }, { focus }, "list")
        steps += test("⌘↑ goes up", in: folder, { press(up, 126, .command) }, { here }, base.lastPathComponent)
        steps += test("Backspace does nothing", in: folder, { press("\u{7f}", 51) }, { here }, "Папка")
        steps += test("⌘[ back", in: folder, { press("[", 33, .command) }, { here }, base.lastPathComponent)
        steps += [(0.6, "⌘] forward", { press("]", 30, .command); check("⌘] forward", here, "Папка") })]
        steps += test("⌘F search", { press("f", 3, .command) }, { focus }, "search")
        steps += test("⌘L address bar", { press("l", 37, .command) }, { focus }, "address")
        steps += counted("⌘R refresh", refreshes) { press("r", 15, .command) }
        steps += counted("⌃⌘F full screen", fullScreens) { press("f", 3, [.command, .control]) }
        steps += trash("⌘⌫ to the Trash (Backspace)") { press("\u{8}", 51, .command) }
        steps += trash("⌘⌫ to the Trash (DEL)") { press("\u{7f}", 51, .command) }
        steps += properties("⌘I properties") { press("i", 34, .command) }
        steps += properties("⌥Enter properties") { press("\r", 36, .option) }
        // Windows
        steps.append(mode(true))
        steps += test("Enter opens", select: "Папка", { press("\r", 36) }, { here }, "Папка")
        steps += test("⌘↓ still opens", select: "Папка", { press(down, 125, .command) }, { here }, "Папка")
        steps += test("F2 renames", select: "file.txt", { press(f2, 120) }, { focus }, "rename")
        steps += test("Backspace goes up", in: folder, { press("\u{7f}", 51) }, { here }, base.lastPathComponent)
        steps += test("⌥↑ goes up", in: folder, { press(up, 126, .option) }, { here }, base.lastPathComponent)
        steps += test("⌘↑ still goes up", in: folder, { press(up, 126, .command) }, { here }, base.lastPathComponent)
        steps += test("⌥← back", in: folder, { press(left, 123, .option) }, { here }, base.lastPathComponent)
        steps += [(0.6, "⌥→ forward", { press(right, 124, .option); check("⌥→ forward", here, "Папка") })]
        steps += test("F3 search", { press(f3, 99) }, { focus }, "search")
        steps += test("F4 address bar", { press(f4, 118) }, { focus }, "address")
        steps += test("⌥D address bar", { press("∂", 2, .option, ignoring: "d") }, { focus }, "address")
        steps += counted("F5 refresh", refreshes) { press(f5, 96) }
        steps += trash("⌦ Delete to the Trash") { press(forwardDelete, 117) }
        steps += [(0.7, "", { reset() }),
                  (0.8, "⇧⌦ deletes for good (after the question)", {
                      s.select("gone.txt")
                      // The question is modal: answer «Удалить» from inside its loop
                      var asked = false
                      let answer = Timer(timeInterval: 0.3, repeats: false) { _ in
                          MainActor.assumeIsolated {
                              asked = NSApp.modalWindow != nil
                              NSApp.stopModal(withCode: .alertFirstButtonReturn)
                          }
                      }
                      RunLoop.main.add(answer, forMode: .modalPanel)
                      press(forwardDelete, 117, .shift)
                      check("asked first", asked ? "asked" : "not asked", "asked", after: 0)
                      check("⇧⌦ deletes for good", s.files().contains("gone.txt") ? "still there" : "gone", "gone", after: 1.2)
                  })]
        steps += [(1.6, "", { reset() }),
                  (0.8, "⇧F10 context menu", {
                      s.select("file.txt")
                      var shown = false
                      var menu: NSMenu?
                      let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                          MainActor.assumeIsolated {
                              shown = true
                              menu = note.object as? NSMenu
                          }
                      }
                      // The menu runs its own loop: closed from inside it
                      let close = Timer(timeInterval: 0.4, repeats: false) { _ in MainActor.assumeIsolated { menu?.cancelTracking() } }
                      RunLoop.main.add(close, forMode: .eventTracking)
                      press(f10, 109, .shift)
                      close.invalidate()
                      NotificationCenter.default.removeObserver(observer)
                      check("⇧F10 context menu", shown ? "menu shown" : "no menu", "menu shown", after: 0)
                  })]
        steps += properties("⌥Enter properties") { press("\r", 36, .option) }
        // Tabs, both modes
        steps += [(0.8, "— Вкладки —", {
                      reset()
                      s.window?.addTab(url: folder)
                      s.window?.addTab(url: base)
                  }),
                  (0.8, "⌃1 first tab", { press("1", 18, .control); check("⌃1 first tab", "\(s.window?.selectedIndex ?? -1)", "0") }),
                  (0.6, "⌃Tab next", { press("\t", 48, .control); check("⌃Tab next", "\(s.window?.selectedIndex ?? -1)", "1") }),
                  (0.6, "⌃⇧Tab previous", { press("\u{19}", 48, [.control, .shift], ignoring: "\t"); check("⌃⇧Tab previous", "\(s.window?.selectedIndex ?? -1)", "0") }),
                  (0.6, "⌃9 last tab", { press("9", 25, .control); check("⌃9 last tab", "\(s.window?.selectedIndex ?? -1)", "2") }),
                  (0.8, "back to Finder keys", { Settings.windowsKeys = false }),
        ]
        s.run(steps)
    }

    /// A real-timed click (button held 0.15 s) beside the breadcrumbs switches to typing with the
    /// whole path selected — five times in a row; Esc brings the breadcrumbs back each time.
    static func addressClick(_ s: Scenario) {
        let base = s.makeFiles(["a.txt"])
        s.window?.navigate(to: base)
        func bar() -> BreadcrumbBar? { s.find(BreadcrumbBar.self, in: s.window?.window?.contentView) }
        func selection() -> String {
            guard let editor = s.window?.window?.firstResponder as? NSTextView else { return "not editing" }
            let range = editor.selectedRange, length = (editor.string as NSString).length
            return range.length == length && length > 0 ? "all" : "\(range.length) of \(length)"
        }
        var results: [String] = []
        func round(_ n: Int) {
            guard n < 5 else {
                s.note("  5 clicks: \(results)  expect all")
                s.run([])
                return
            }
            guard let bar = bar(), let window = bar.window else { s.note("  (no breadcrumbs)"); s.run([]); return }
            window.makeFirstResponder(s.table)
            let point = bar.convert(NSPoint(x: bar.bounds.maxX - 12, y: bar.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let release = Timer(timeInterval: 0.15, repeats: false) { _ in
                if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            }
            RunLoop.main.add(release, forMode: .common)
            if let down = event(.leftMouseDown) { NSApp.sendEvent(down) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                results.append(selection())
                s.key("\u{1b}", code: 53)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { round(n + 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { round(0) }
    }

    /// The breadcrumb bar: steps for a few places, a click on a step, a click beside them (typing),
    /// Esc back; photographed wide (scripts/capture-window.sh breadcrumbs).
    static func breadcrumbs(_ s: Scenario) {
        let deep = s.makeFiles(["x.txt"], in: "Проекты/2026/Отчёты")
        let fm = FileManager.default
        for place in [fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"), Places.trashURL, Places.computerURL] {
            let crumbs = BreadcrumbBar.path(for: Location(place)).crumbs.map(\.title)
            s.note("  \(place.lastPathComponent): \(crumbs.joined(separator: " › "))")
        }
        s.window?.navigate(to: deep)
        s.window?.window?.setFrame(NSRect(x: 150, y: 200, width: 1400, height: 600), display: true)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        func bar() -> BreadcrumbBar? { s.find(BreadcrumbBar.self, in: s.window?.window?.contentView) }
        func buttons() -> [CrumbButton] { bar().map { s.findAll(CrumbButton.self, in: $0) } ?? [] }
        s.run([
            (1.0, "photograph", {
                s.note("  steps: \(buttons().compactMap(\.toolTip).suffix(4))")
                if let window = s.window?.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
            }),
            (2.0, "click the step «Проекты»", {
                guard let step = buttons().first(where: { $0.toolTip?.hasSuffix("/Проекты") == true }), let event = NSApp.currentEvent else { s.note("  (no step)"); return }
                step.mouseDown(with: event)
            }),
            (0.6, "where", { s.note("  now in: \(s.window?.selectedTab.title ?? "?")  expect Проекты") }),
            (0.2, "click beside the steps", {
                guard let bar = bar(), let window = bar.window,
                      let event = NSEvent.mouseEvent(with: .leftMouseDown, location: bar.convert(NSPoint(x: bar.bounds.maxX - 10, y: bar.bounds.midY), to: nil),
                                                     modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                bar.mouseDown(with: event)
            }),
            (0.4, "typing?", {
                let editor = s.window?.window?.firstResponder as? NSTextView
                let all = editor.map { $0.selectedRange.length == ($0.string as NSString).length } ?? false
                s.note("  typing: \(editor != nil), all selected: \(all), breadcrumbs hidden: \(bar()?.isHidden == true)  expect true, true, true")
                s.key("\u{1b}", code: 53)
            }),
            (0.4, "after Esc", { s.note("  breadcrumbs back: \(bar()?.isHidden == false)  expect true") }),
        ])
    }

    /// Sidebar drops without the mouse (a stand-in NSDraggingInfo goes to the data source):
    /// folders pinned between the favourites, favourites reordered, files dropped on a folder,
    /// on a tag, on the Trash bar; then the sidebar and the Trash are photographed.
    static func sidebar(_ s: Scenario) {
        let base = s.makeFiles(["в папку.txt", "с тегом.txt"])
        let fm = FileManager.default
        for name in ["Альфа", "Бета", "Цель"] { try? fm.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true) }
        let (alpha, beta, target) = (base.appendingPathComponent("Альфа"), base.appendingPathComponent("Бета"), base.appendingPathComponent("Цель"))
        s.window?.navigate(to: base)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        func outline() -> NSOutlineView? {
            s.findAll(NSOutlineView.self, in: s.window?.window?.contentView ?? NSView()).first { $0.dataSource is SidebarViewController }
        }
        func sidebar() -> SidebarViewController? { outline()?.dataSource as? SidebarViewController }
        func section(_ kind: SidebarViewController.Section.Kind) -> SidebarViewController.Section? {
            guard let outline = outline() else { return nil }
            return (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? SidebarViewController.Section }.first { $0.kind == kind }
        }
        func favorites() -> [String] { section(.favorites)?.items.map(\.title) ?? [] }
        func drop(_ info: FakeDrag, on item: Any?, index: Int) -> String {
            guard let outline = outline(), let sidebar = sidebar() else { return "no sidebar" }
            let operation = sidebar.outlineView(outline, validateDrop: info, proposedItem: item, proposedChildIndex: index)
            guard operation != [] else { return "refused" }
            return sidebar.outlineView(outline, acceptDrop: info, item: item, childIndex: index) ? "op \(operation.rawValue)" : "failed"
        }
        s.run([
            (1.0, "pin Альфа", {
                SidebarConfig.pin(alpha)
                s.note("  favourites end with: \(favorites().suffix(2))  expect […, Альфа]")
            }),
            (0.3, "drop Бета between the first two favourites", {
                let result = drop(FakeDrag(urls: [beta]), on: section(.favorites), index: 1)
                s.note("  \(result); favourites start: \(favorites().prefix(3))  expect Бета second")
            }),
            (0.3, "drop a file between favourites (only folders pin)", {
                s.note("  \(drop(FakeDrag(urls: [base.appendingPathComponent("в папку.txt")]), on: section(.favorites), index: 0))  expect refused")
            }),
            (0.3, "drag favourite Альфа to the top", {
                let result = drop(FakeDrag(favorite: alpha.path), on: section(.favorites), index: 0)
                s.note("  \(result); favourites start: \(favorites().prefix(3))  expect Альфа first")
            }),
            (0.3, "pin Цель, drop a file on it", {
                SidebarConfig.pin(target)
                let item = section(.favorites)?.items.first { $0.title == "Цель" }
                s.note("  \(drop(FakeDrag(urls: [base.appendingPathComponent("в папку.txt")]), on: item, index: -1))")
            }),
            (1.5, "moved?", { s.note("  in Цель: \(s.files(in: target))  expect [в папку.txt]") }),
            (0.2, "drop a file on the tag «Красный»", {
                let item = section(.tags)?.items.first { $0.title == "Красный" }
                let file = base.appendingPathComponent("с тегом.txt")
                s.note("  \(drop(FakeDrag(urls: [file]), on: item, index: -1)); tags: \(FileTags.tags(of: file).map(\.name))  expect [Красный]")
            }),
            (0.3, "remove Бета from the sidebar", {
                SidebarConfig.unpin(beta)
                s.note("  favourites: \(favorites())")
            }),
            (0.5, "photograph the sidebar", {
                if let window = s.window?.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
            }),
            (1.5, "the Trash", { s.window?.navigate(to: Places.trashURL) }),
            (1.0, "photograph the Trash", {
                if let window = s.window?.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-1"), atomically: true, encoding: .utf8)
                }
            }),
            (1.5, "unpin the sandbox folders", { [alpha, target].forEach(SidebarConfig.unpin) }),
        ])
    }

    /// The command bar, its menus, the column header menu and the address bar menu, each
    /// photographed by scripts/capture-window.sh commandbar 7.
    static func commandBarScenario(_ s: Scenario) {
        let base = s.makeFiles(["отчёт.docx", "заметки.txt", "фото.png"])
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        s.window?.window?.setFrame(NSRect(x: 150, y: 200, width: 1200, height: 560), display: true)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        let content = s.window?.window?.contentView
        func bar() -> CommandBar? { s.find(CommandBar.self, in: content) }
        /// Hands a window to the script and goes on once it has been photographed.
        @MainActor func shot(_ index: Int, window number: Int?, then next: @escaping @MainActor () -> Void) {
            if let number { try? "\(number)".write(to: s.output.appendingPathComponent("tab-\(index)"), atomically: true, encoding: .utf8) }
            @MainActor func wait(_ tries: Int) {
                if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-\(index)").path) || tries == 0 || number == nil { return next() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { wait(tries - 1) }
            }
            wait(50)
        }
        /// Opens a menu (the call blocks while it tracks), photographs it, closes it with Esc.
        @MainActor func menuShot(_ index: Int, open: () -> Void, then next: @escaping @MainActor () -> Void) {
            let find = Timer(timeInterval: 0.6, repeats: false) { _ in
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let menus = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) == 101 }
                if let number = menus.first?[kCGWindowNumber as String] as? Int {
                    try? "\(number)".write(to: s.output.appendingPathComponent("tab-\(index)"), atomically: true, encoding: .utf8)
                } else {
                    s.note("  (no menu window)")
                }
                let close = Timer(timeInterval: 0.2, repeats: true) { timer in
                    guard FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-\(index)").path) || menus.isEmpty else { return }
                    timer.invalidate()
                    if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(esc, atStart: false)
                    }
                }
                RunLoop.main.add(close, forMode: .common)
            }
            RunLoop.main.add(find, forMode: .common)
            // The sort menu: highlight "Дополнительно" (↓ × 4) and open it (→), for the arrow
            if index == 1 {
                let keys = Timer(timeInterval: 0.25, repeats: false) { _ in
                    for (key, code) in [(NSDownArrowFunctionKey, 125), (NSDownArrowFunctionKey, 125), (NSDownArrowFunctionKey, 125),
                                        (NSDownArrowFunctionKey, 125), (NSRightArrowFunctionKey, 124)] {
                        guard let scalar = UnicodeScalar(key) else { continue }
                        let text = String(Character(scalar))
                        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                                        isARepeat: false, keyCode: UInt16(code)) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
                RunLoop.main.add(keys, forMode: .common)
            }
            open()
            DispatchQueue.main.async { next() }
        }
        func rightClick(_ view: NSView, at point: NSPoint) -> NSEvent? {
            guard let window = view.window else { return nil }
            return NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            s.select("заметки.txt")
            s.note("  bar: \(bar() != nil), cut enabled: \(bar()?.cutButton.isEnabled == true), new enabled: \(bar()?.newButton.isEnabled == true)  expect true, true, true")
            if let bar = bar(), let content = bar.window?.contentView {
                let tips = [bar.cutButton, bar.copyButton, bar.pasteButton, bar.renameButton, bar.shareButton, bar.deleteButton, bar.moreButton].map { button in
                    content.hitTest(content.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button))?.toolTip ?? "none"
                }
                s.note("  tooltips under the mouse: \(tips)")
            }
            shot(0, window: s.window?.window?.windowNumber) {
                menuShot(1, open: { bar()?.sortButton.onClick?() }) {
                    menuShot(2, open: { bar()?.viewButton.onClick?() }) {
                        menuShot(3, open: { bar()?.moreButton.onClick?() }) {
                            guard let table = s.table, let header = table.headerView,
                                  let typeColumn = Optional(table.column(withIdentifier: .init("type"))), typeColumn >= 0,
                                  let event = rightClick(header, at: NSPoint(x: header.headerRect(ofColumn: typeColumn).midX, y: header.bounds.midY)) else {
                                s.note("  (no header)"); s.run([]); return
                            }
                            menuShot(4, open: {
                                if let menu = header.menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: header) }
                            }) {
                                guard let crumbs = s.find(BreadcrumbBar.self, in: content),
                                      let event = rightClick(crumbs, at: NSPoint(x: crumbs.bounds.maxX - 30, y: crumbs.bounds.midY)) else {
                                    s.note("  (no address bar)"); s.run([]); return
                                }
                                menuShot(5, open: {
                                    if let menu = crumbs.menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: crumbs) }
                                }) {
                                    // Show "Дата создания", fit every column
                                    guard let table = s.table else { s.run([]); return }
                                    table.tableColumn(withIdentifier: .init("created"))?.isHidden = false
                                    let before = table.tableColumns.filter { !$0.isHidden }.map { "\($0.identifier.rawValue) \(Int($0.width))" }
                                    s.note("  columns: \(before)")
                                    shot(6, window: s.window?.window?.windowNumber) { s.run([]) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// With "Просмотреть" open, a click on "Сортировать" should open the sort menu (Explorer),
    /// and nothing should reopen "Просмотреть" afterwards. Clicks are posted events.
    static func menuSwitch(_ s: Scenario) {
        let base = s.makeFiles(["a.txt"])
        s.window?.navigate(to: base)
        s.window?.window?.setFrame(NSRect(x: 150, y: 200, width: 1200, height: 560), display: true)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        var opened: [String] = []
        func bar() -> CommandBar? { s.find(CommandBar.self, in: s.window?.window?.contentView) }
        func click(_ button: NSView) {
            guard let window = button.window else { return }
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let bar = bar() else { s.note("  (no bar)"); s.run([]); return }
            bar.onMenuOpen = { opened.append($0) }
            click(bar.viewButton)
            // While "Просмотреть" tracks: click "Сортировать"
            let second = Timer(timeInterval: 0.8, repeats: false) { _ in click(bar.sortButton) }
            RunLoop.main.add(second, forMode: .common)
            // Close whatever is open after that
            let closer = Timer(timeInterval: 0.4, repeats: true) { timer in
                guard opened.count >= 2 else { return }
                timer.invalidate()
                if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                              isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(esc, atStart: false)
                }
            }
            RunLoop.main.add(closer, forMode: .common)
            s.run([
                (3.5, "menus opened", { s.note("  \(opened)  expect [view, sort]") }),
                (0.2, "click Сортировать once more", { opened = []; click(bar.sortButton) }),
                (1.0, "which opened", {
                    s.note("  \(opened)  expect [sort]")
                    if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(esc, atStart: false)
                    }
                }),
            ])
        }
    }

    /// The properties window: a photo with camera data (all three tabs), a folder, an app's
    /// details. Photographed by scripts/capture-window.sh properties 5.
    static func properties(_ s: Scenario) {
        let photo = s.sandbox.appendingPathComponent("фото.jpg")
        let size = 640
        if let context = CGContext(data: nil, width: size, height: size / 4 * 3, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            if let image = context.makeImage(),
               let destination = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil) {
                let properties: [CFString: Any] = [
                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R6"],
                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:07:14 18:32:05",
                                                     kCGImagePropertyExifExposureTime: 1.0 / 250, kCGImagePropertyExifFNumber: 2.8,
                                                     kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifFocalLength: 35.0,
                                                     kCGImagePropertyExifLensModel: "RF 35mm F1.8 MACRO IS STM"],
                    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.7539, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 37.6208, kCGImagePropertyGPSLongitudeRef: "E"],
                ]
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
                CGImageDestinationFinalize(destination)
            }
        }
        let folder = s.makeFiles(["a.txt", "b.txt"], in: "Папка")
        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(L("Свойства")) } }
        func tabs() -> PropertiesTabBar? { s.find(PropertiesTabBar.self, in: window()?.contentView) }
        @MainActor func shot(_ index: Int, then next: @escaping @MainActor () -> Void) {
            guard let number = window()?.windowNumber else { s.note("  (no window for shot \(index))"); return next() }
            s.note("  shot \(index): \(window()?.title ?? "") \(Int(window()?.frame.height ?? 0)) pt")
            try? "\(number)".write(to: s.output.appendingPathComponent("tab-\(index)"), atomically: true, encoding: .utf8)
            @MainActor func wait(_ tries: Int) {
                if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-\(index)").path) || tries == 0 { return next() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { wait(tries - 1) }
            }
            wait(50)
        }
        func after(_ seconds: Double, _ block: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { block() }
        }
        NSApp.activate(ignoringOtherApps: true)
        PropertiesWindowController.show(for: [photo])
        after(1.5) {
            shot(0) {
                tabs()?.onSelect?(1)
                after(2.0) {
                    shot(1) {
                        tabs()?.onSelect?(2)
                        after(1.0) {
                            shot(2) {
                                window()?.close()
                                PropertiesWindowController.show(for: [folder])
                                after(1.5) {
                                    shot(3) {
                                        window()?.close()
                                        PropertiesWindowController.show(for: [URL(fileURLWithPath: "/System/Applications/Calculator.app")])
                                        after(1.0) {
                                            tabs()?.onSelect?(1)
                                            after(1.5) {
                                                shot(4) {
                                                    window()?.close()
                                                    // WINEX_PROPS_FILE: one more file's details (read only)
                                                    guard let extra = ProcessInfo.processInfo.environment["WINEX_PROPS_FILE"] else { return s.run([]) }
                                                    PropertiesWindowController.show(for: [URL(fileURLWithPath: extra)])
                                                    after(1.0) {
                                                        tabs()?.onSelect?(1)
                                                        after(2.5) { shot(5) { window()?.close(); s.run([]) } }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// "Открыть в терминале": off by default, then in the file, folder-background and desktop
    /// menus (nothing is launched).
    static func terminalMenu(_ s: Scenario) {
        let base = s.makeFiles(["a.txt"])
        s.window?.navigate(to: base)
        s.note("  terminals here: \(TerminalLauncher.installed.map(\.name)); chosen: \(TerminalLauncher.chosen?.name ?? "none")")
        s.note("  off by default: \(TerminalLauncher.menuItem(for: [base]) == nil)  expect true")
        Settings.terminalInMenu = true
        let item = TerminalLauncher.menuItem(for: [base.appendingPathComponent("a.txt")])
        s.note("  item: \(item?.title ?? "none")")
        let script = base.appendingPathComponent("скрипт.sh")
        try? "echo hi".write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        s.note("  script: \(TerminalLauncher.isScript(script)), \(TerminalLauncher.menuItem(for: [script])?.title ?? "none"); a.txt: \(TerminalLauncher.isScript(base.appendingPathComponent("a.txt")))  expect true, Запустить в …, false")
        s.run([
            (1.0, "file menu", {
                s.select("a.txt")
                guard let table = s.table, let menu = table.menu else { s.note("  (no table)"); return }
                menu.delegate?.menuNeedsUpdate?(menu)
                s.note("  has it: \(menu.items.contains { $0.action == NSSelectorFromString("openFromMenu:") })  expect true")
            }),
            (0.3, "folder menu", {
                try? FileManager.default.createDirectory(at: base.appendingPathComponent("папка"), withIntermediateDirectories: true)
                s.window?.refresh(nil)
            }),
            (0.8, "folder menu items", {
                s.setViewMode(.details)
                s.select("папка")
                guard let table = s.table, let menu = table.menu else { return }
                s.note("  selected: \(s.selectedNames)")
                guard let list = table.delegate as? FileListViewController else { return }
                menu.removeAllItems()
                FileContextMenu.addItems(to: menu, for: [base.appendingPathComponent("папка")], target: list, folderTabs: true, customizableFolder: true)
                s.note("  folder menu: \(menu.items.map { $0.attributedTitle?.string.trimmingCharacters(in: .whitespaces) ?? $0.title }.filter { !$0.isEmpty })")
            }),
            (0.3, "squeeze the window", {
                guard let window = s.window?.window else { return }
                window.setFrame(NSRect(x: 200, y: 200, width: 800, height: 500), display: true)
                window.layoutIfNeeded()
                let sidebar = s.findAll(NSOutlineView.self, in: window.contentView ?? NSView()).first?.enclosingScrollView?.superview
                s.note("  window \(Int(window.frame.width)), sidebar \(Int(sidebar?.frame.width ?? 0))  expect window ≥ 760, sidebar ≥ 170")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
            }),
            (2.0, "photographed", {}),
        ])
    }

    /// A language change restarts WinEx with the same windows: saved, closed, restored here
    /// (without the restart itself). Also: «Как в системе» follows macOS, not WinEx's language.
    static func session(_ s: Scenario) {
        let a = s.makeFiles(["1.txt"], in: "A"), b = s.makeFiles(["2.txt"], in: "B")
        s.note("  running English: \(Localization.isEnglish); system language means: \(Localization.resolved(.system))")
        let app = AppDelegate.shared
        app.windowControllers.forEach { $0.window?.close() }
        let first = app.openWindow(at: a)
        first.addTab(url: b)
        first.window?.setFrame(NSRect(x: 120, y: 140, width: 900, height: 560), display: true)
        let second = app.openWindow(at: b)
        second.window?.setFrame(NSRect(x: 300, y: 200, width: 820, height: 500), display: true)
        func describe() -> [String] {
            app.windowControllers.filter { $0.window?.isVisible == true }.map {
                "\($0.tabs.map(\.url.lastPathComponent)) sel \($0.selectedIndex) \(Int($0.window?.frame.minX ?? 0)),\(Int($0.window?.frame.minY ?? 0)) \(Int($0.window?.frame.width ?? 0))"
            }.sorted()
        }
        s.run([
            (0.8, "save and close", {
                s.note("  before: \(describe())")
                app.saveSession(settingsOpen: true)
                app.windowControllers.forEach { $0.window?.close() }
            }),
            (0.8, "restore", {
                s.note("  restored something: \(app.restoreSession())")
            }),
            (0.8, "compare", {
                s.note("  after:  \(describe())  expect the same")
                s.note("  settings open: \(NSApp.windows.contains { $0.isVisible && $0.contentViewController is NSTabViewController })  expect true")
                s.note("  session cleared: \(!app.restoreSession())  expect true")
            }),
        ])
    }

    /// Settings ▸ Программы: an added app with its own item, a hidden app, a custom template.
    static func appsSettings(_ s: Scenario) {
        let base = s.makeFiles(["заметка.rtf"])
        let folder = base.appendingPathComponent("проект")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = NSWorkspace.shared
        let code = workspace.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
        let pages = workspace.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages")
        if let code { AppsConfig.apps = [AppsConfig.App(path: code.path, scope: .all, extensions: ["rtf", "md"], inMainMenu: true)] }
        if let pages { AppsConfig.hiddenApps = [AppsConfig.identity(of: pages)] }
        let sample = base.appendingPathComponent("образец.md")
        try? "# Заметка\n".write(to: sample, atomically: true, encoding: .utf8)
        AppsConfig.templates = [AppsConfig.Template(title: "Заметка Markdown", fileName: "Заметка.md", sourcePath: sample.path)]
        AppsConfig.hiddenTemplates = ["pptx"]
        func titles(_ item: NSMenuItem?) -> [String] { item?.submenu?.items.map(\.title).filter { !$0.isEmpty } ?? [] }
        s.note("  VS Code: \(code != nil), Pages: \(pages != nil)")
        s.note("  folder «Открыть с помощью»: \(titles(OpenWithMenu.item(for: [folder])))")
        s.note("  folder own items: \(OpenWithMenu.mainMenuItems(for: [folder]).map(\.title))  expect [Открыть в Visual Studio Code]")
        let rtf = base.appendingPathComponent("заметка.rtf")
        s.note("  rtf «Открыть с помощью»: \(titles(OpenWithMenu.item(for: [rtf])))  expect no Pages")
        s.note("  rtf own items: \(OpenWithMenu.mainMenuItems(for: [rtf]).map(\.title))")
        let script = base.appendingPathComponent("скрипт.sh")
        try? "echo".write(to: script, atomically: true, encoding: .utf8)
        let opener = workspace.urlForApplication(toOpen: script).map(OpenWithMenu.appName) ?? "-"
        if let code { AppsConfig.apps = [AppsConfig.App(path: code.path, scope: .all, extensions: [], inMainMenu: true)] }
        s.note("  .sh opens with \(opener); own items: \(OpenWithMenu.mainMenuItems(for: [script]).map(\.title))  expect none if VS Code is the default")
        s.note("  «Создать»: \(NewItemTemplate.availableFiles.map(\.title))  expect no PowerPoint, + Заметка Markdown")
        if let custom = NewItemTemplate.availableFiles.last, let made = try? custom.create(in: folder) {
            s.note("  created \(made.lastPathComponent): \((try? String(contentsOf: made, encoding: .utf8)) ?? "?")")
        }
        AppDelegate.shared.showSettings(tab: .apps)
        s.run([
            (1.2, "photograph", {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentViewController is NSTabViewController }) {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
            }),
            (2.0, "done", {}),
        ])
    }

    /// Settings saved to a file, changed, loaded back; then reset (desktop layout kept).
    static func backup(_ s: Scenario) {
        Settings.showHidden = true
        Settings.windowsKeys = true
        SidebarConfig.showsTags = false
        AppDefaults.store.set(Data([1, 2, 3]), forKey: "desktopLayout")
        TagLibrary.favoriteNames = ["Работа", "Дом"]
        let sample = s.sandbox.appendingPathComponent("образец.md")
        try? "# Образец".write(to: sample, atomically: true, encoding: .utf8)
        AppsConfig.templates = [AppsConfig.Template(title: "Заметка", fileName: "Заметка.md", sourcePath: sample.path)]
        guard let data = try? SettingsBackup.fileData() else { s.note("  (no file)"); s.run([]); return }
        s.note("  file: \(data.count) bytes, readable: \(SettingsBackup.read(data) != nil)")
        Settings.showHidden = false
        Settings.windowsKeys = false
        SidebarConfig.showsTags = true
        TagLibrary.favoriteNames = ["Красный"]
        try? FileManager.default.removeItem(at: sample)  // as on another Mac
        if let file = SettingsBackup.read(data) { SettingsBackup.apply(file.settings, extras: file.extras) }
        let restored = AppsConfig.templates.first?.sourcePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        s.note("  favourite tags: \(TagLibrary.favoriteNames)  expect [Работа, Дом]")
        s.note("  sample restored: \(restored ?? "none")  expect # Образец")
        s.note("  after loading: hidden \(Settings.showHidden), windows keys \(Settings.windowsKeys), sidebar tags \(SidebarConfig.showsTags)  expect true, true, false")
        SettingsBackup.reset()
        s.note("  after reset: hidden \(Settings.showHidden), windows keys \(Settings.windowsKeys), sidebar tags \(SidebarConfig.showsTags)  expect false, false, true")
        s.note("  desktop layout kept: \(AppDefaults.store.data(forKey: "desktopLayout") == Data([1, 2, 3]))  expect true")
        s.note("  not a settings file: \(SettingsBackup.read(Data("hello".utf8)) == nil)  expect true")
        s.run([])
    }

    /// A tab from another window over this window's strip: it's shown there before the drop.
    static func tabMerge(_ s: Scenario) {
        let a = s.makeFiles(["1.txt"], in: "Первая"), b = s.makeFiles(["2.txt"], in: "Вторая")
        let app = AppDelegate.shared
        app.windowControllers.forEach { $0.window?.close() }
        let target = app.openWindow(at: a)
        target.addTab(url: s.sandbox)
        target.window?.setFrame(NSRect(x: 150, y: 200, width: 1100, height: 500), display: true)
        let source = app.openWindow(at: b)
        source.window?.setFrame(NSRect(x: 600, y: 120, width: 700, height: 400), display: true)
        s.run([
            (1.0, "hover over the strip", {
                guard let bar = target.tabBar.window.map({ _ in target.tabBar }) else { return }
                let point = NSPoint(x: bar.screenFrame.minX + 150, y: bar.screenFrame.midY)
                s.note("  target found: \(app.mergeTarget(for: source.window ?? NSWindow(), at: point) === target)  expect true")
                bar.showIncoming(title: source.selectedTab.title, icon: source.selectedTab.location.icon, atScreenPoint: point)
                source.window?.alphaValue = 0
                target.window?.orderFront(nil)
            }),
            (0.6, "photograph", {
                if let number = target.window?.windowNumber {
                    try? "\(number)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
            }),
            (1.5, "drop", {
                target.tabBar.clearIncoming()
                app.windowDragEnded(source.window ?? NSWindow(), at: NSPoint(x: target.tabBar.screenFrame.minX + 150, y: target.tabBar.screenFrame.midY))
                s.note("  tabs now: \(target.tabs.map(\.title))  expect Вторая second")
            }),
        ])
    }

    /// Every step of the setup assistant, photographed (scripts/capture-window.sh wizard 8).
    static func wizard(_ s: Scenario) {
        AppDelegate.shared.windowControllers.forEach { $0.window?.close() }
        // With WinEx's desktop (in the scenario's own settings) the zones step is there too
        let zones = ProcessInfo.processInfo.environment["WINEX_WIZARD_ZONES"] != nil
        if zones { Settings.replaceFinder = true }
        let last = zones ? 8 : 7
        SetupWizard.show()
        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.windowController is SetupWizard } }
        @MainActor func step(_ index: Int) {
            guard let window = window() else { s.note("  (no wizard)"); return s.run([]) }
            // The other choice on the pages with pictures, so the pictures show it
            func click(_ title: String) {
                guard let content = window.contentView,
                      let label = s.findAll(NSTextField.self, in: content).first(where: { $0.stringValue == title }),
                      let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { s.note("  (no «\(title)»)"); return }
                content.hitTest(content.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), from: label))?.mouseDown(with: event)
            }
            switch index {
            case 4 where zones && ProcessInfo.processInfo.environment["WINEX_WIZARD_DEFAULTS"] == nil: click(L("Зоны на рабочем столе"))
            case 3 where ProcessInfo.processInfo.environment["WINEX_WIZARD_DEFAULTS"] == nil: click(L("Окна и рабочий стол"))
            case 4: click(L("Как в Windows"))
            case 5:
                click(ViewMode.details.title)
                click(L("Показывать скрытые файлы"))
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-\(index)"), atomically: true, encoding: .utf8)
            }
            if index == 3, let content = window.contentView,
               let label = s.findAll(NSTextField.self, in: content).first(where: { $0.stringValue.hasPrefix(L("Finder остаётся")) }) {
                // A click on a card's text lands on the card, not on a selectable label
                let hit = content.hitTest(content.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), from: label))
                s.note("  card text under the mouse: \(hit.map { String(describing: type(of: $0)) } ?? "nil")  expect WizardCard")
            }
            @MainActor func wait(_ tries: Int) {
                if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-\(index)").path) || tries == 0 {
                    guard index < last else { window.close(); return s.run([]) }
                    // "Пропустить" (so nothing is applied to the scenario's settings… or the Mac)
                    let skip = s.findAll(NSButton.self, in: window.contentView ?? NSView()).first { $0.title == L(index == 0 ? "Начать" : "Пропустить") }
                    if index == 0 { skip?.performClick(nil) } else { skip?.performClick(nil) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { step(index + 1) }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { wait(tries - 1) }
            }
            wait(50)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            step(0)
        }
    }

    /// `open` in the Terminal: the block goes into (a stand-in) ~/.zshrc and comes out cleanly.
    /// Run with WINEX_SHELL_HOME=<dir>.
    static func shell(_ s: Scenario) {
        do {
            try ShellIntegration.install()
            try ShellIntegration.install()  // twice: still one block
            s.note("  installed: \(ShellIntegration.isInstalled)  expect true")
            if ProcessInfo.processInfo.environment["WINEX_SHELL_REMOVE"] != nil {
                try ShellIntegration.uninstall()
                s.note("  removed: \(!ShellIntegration.isInstalled)  expect true")
            }
        } catch { s.note("  error: \(error)") }
        s.run([])
    }

    /// Fences on the desktop: one made from three icons (they move inside), rolled up (hidden),
    /// unrolled; snapping math; the desktop photographed (scripts/capture-window.sh fences).
    static func fences(_ s: Scenario) {
        let controller = DesktopController()
        controller.show()
        func mainView() -> DesktopView? {
            NSApp.windows.lazy.compactMap { $0.contentView as? DesktopView }.first { $0.window?.screen == NSScreen.screens.first }
        }
        // Snapping: 5 pt from another fence's right edge (+ gap) → clings to it
        let area = NSRect(x: 0, y: 30, width: 1500, height: 900)
        let other = NSRect(x: 100, y: 100, width: 300, height: 200)
        let (snapped, guides) = FenceSnap.snap(NSRect(x: 413, y: 104, width: 300, height: 200), edges: [.minX, .maxX, .minY, .maxY], area: area, others: [other])
        s.note("  snap: x \(Int(snapped.minX)) y \(Int(snapped.minY)), guides \(guides.count)  expect x 408 (400 + gap), y 100")
        let (resized, _) = FenceSnap.snap(NSRect(x: 100, y: 400, width: 295, height: 200), edges: [.maxX], area: area, others: [other])
        s.note("  resize: width \(Int(resized.width))  expect 300 (right edges lined up)")
        s.run([
            (2.0, "make a fence of three icons", {
                guard let view = mainView() else { s.note("  (no desktop)"); return }
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                    .filter { !$0.hasPrefix(".") }.sorted().prefix(3)
                guard let id = view.debugMakeFence(at: NSPoint(x: 420, y: 160), members: Array(names)) else { s.note("  (no fence)"); return }
                view.needsDisplay = true
                view.displayIfNeeded()
                guard let fenceView = view.debugFenceView(id) else { s.note("  (no fence view)"); return }
                // The title being edited: typed, then a click elsewhere keeps it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let field = fenceView.subviews.compactMap({ $0 as? NSTextField }).first {
                        let textY = field.frame.midY
                        field.stringValue = "Документы"
                        view.window?.makeFirstResponder(view)
                        s.note("  renamed by clicking away: \(view.layout.fences.last?.title ?? "?"), field centred at \(Int(textY))  expect Документы, 15")
                    } else { s.note("  (no rename field)") }
                }
                let inside = names.compactMap { view.debugCenter(of: $0) }.allSatisfy { fenceView.frame.contains($0) }
                s.note("  fence \(Int(fenceView.frame.width))×\(Int(fenceView.frame.height)); icons inside: \(inside)  expect true")
                if let window = view.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
            }),
            (2.0, "select two icons outside: the hint", {
                guard let view = mainView() else { return }
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                    .filter { !$0.hasPrefix(".") }.sorted().dropFirst(3).prefix(2)
                view.debugSelect(Array(names))
                if let window = view.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-1"), atomically: true, encoding: .utf8)
                }
            }),
            (2.0, "roll up", {
                guard let view = mainView(), let fence = view.layout.fences.last, let name = fence.members.first else { return }
                view.debugSelect([])
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                    .filter { !$0.hasPrefix(".") && !fence.members.contains($0) }
                // One outside icon stored under the fence: shown beside it, and it must stay there
                if let under = names.first, let box = view.debugFenceView(fence.id)?.frame {
                    view.debugPlace(under, at: CGPoint(x: box.midX, y: box.midY))
                }
                let before = names.map { view.debugCenter(of: $0) }
                view.debugToggle(fence.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    s.note("  rolled up hides icons: \(view.debugIsHidden(name))  expect true")
                    s.note("  other icons stayed put: \(names.map { view.debugCenter(of: $0) } == before)  expect true")
                    if let window = view.window {
                        try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-2"), atomically: true, encoding: .utf8)
                    }
                }
            }),
            (2.5, "roll down", {
                guard let view = mainView(), let fence = view.layout.fences.last, let name = fence.members.first else { return }
                view.debugToggle(fence.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    s.note("  unrolled shows icons: \(!view.debugIsHidden(name))  expect true")
                }
            }),
            (1.0, "a zone too small for its icons scrolls smoothly", {
                guard let view = mainView(), let window = view.window, let fence = view.layout.fences.first(where: { !$0.members.isEmpty }) else { return }
                // Wide enough for two icons a row, tall enough for one and a half rows
                let frame = NSRect(x: fence.x, y: fence.y, width: 240, height: DesktopFence.titleHeight + view.debugCellHeight * 1.5)
                view.debugSetFenceFrame(fence.id, frame)
                view.displayIfNeeded()
                // The zone's scroll view moves (as a trackpad moves it): the icons follow
                let fenceView = view.debugFenceView(fence.id)
                fenceView?.debugScroll(to: 40)
                s.note("  scrolled: \(Int(view.debugScroll(fence.id))) pt  expect 40")
                s.note("    \(fenceView?.debugScrollState ?? "no fence view")")
                // Pulled past the top, as the rubber band does: the icons go along
                fenceView?.debugScroll(to: -30)
                s.note("  pulled past the top: \(Int(view.debugScroll(fence.id))) pt  expect -30")
                // Exactly as tall as its rows (what the snapping gives): nothing to scroll
                let rows = Int(ceil(Double(fence.members.count) / 2))
                let whole = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: view.debugRowsHeight(rows))
                view.debugSetFenceFrame(fence.id, whole)
                view.displayIfNeeded()
                s.note("  sized to its \(rows) rows: can scroll \(Int(view.debugMaxScroll(fence.id))) pt, scroll view: \(fenceView?.debugScrollState.hasPrefix("no scroll view") == true ? "none" : "there")  expect 0, none")
                view.debugSetFenceFrame(fence.id, frame)
                view.displayIfNeeded()
                view.debugFenceView(fence.id)?.debugScroll(to: 0)
                view.displayIfNeeded()
                // A rubber band just under the zone: the icons cut off at its bottom aren't caught
                let zoneFrame = view.debugFenceView(fence.id)?.frame ?? .zero
                func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                if let down = mouse(.leftMouseDown, NSPoint(x: zoneFrame.minX + 4, y: zoneFrame.maxY + 6)) { view.mouseDown(with: down) }
                if let drag = mouse(.leftMouseDragged, NSPoint(x: zoneFrame.maxX - 4, y: zoneFrame.maxY + 70)) { view.mouseDragged(with: drag) }
                let caught = view.debugSelectedNames.filter { fence.members.contains($0) }
                if let up = mouse(.leftMouseUp, NSPoint(x: zoneFrame.maxX - 4, y: zoneFrame.maxY + 70)) { view.mouseUp(with: up) }
                s.note("  rubber band under the zone caught its icons: \(caught)  expect []")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-3"), atomically: true, encoding: .utf8)
            }),
            (1.0, "let go of a dragged icon: it glides to its place", {
                guard let view = mainView(), let name = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                        .first(where: { name in !name.hasPrefix(".") && !view.layout.fences.contains { $0.members.contains(name) } && view.debugCenter(of: name) != nil }),
                      let spot = view.debugEmptySpot(NSSize(width: 200, height: 200)) else { return }
                // Let go between grid cells, with the grid on: it pulls the icon into a cell
                view.layout.alignToGrid = true
                s.note("  align to grid: \(view.layout.alignToGrid)")
                let drop = NSPoint(x: spot.midX + 17, y: spot.midY + 13)
                let origin = view.debugCenter(of: name)
                view.debugDrop(name, at: drop)
                guard let place = view.debugCenter(of: name), let origin else { return }
                func distance(_ a: CGPoint, _ b: CGPoint) -> Int { Int(hypot(a.x - b.x, a.y - b.y)) }
                // A moment later, on screen: near the drop point (not on its way from where it was)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    guard let frames = view.debugTileFrames(name) else { return }
                    let shown = CGPoint(x: frames.shown.midX, y: frames.shown.midY)
                    let offset = CGPoint(x: frames.place.midX - place.x, y: frames.place.midY - place.y)
                    let shownCenter = CGPoint(x: shown.x - offset.x, y: shown.y - offset.y)
                    s.note("  after 0.03 s: \(distance(shownCenter, drop)) pt from the drop point, \(distance(shownCenter, origin)) from where it was (drop → place: \(distance(drop, place)))  expect small, large")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let frames = view.debugTileFrames(name) {
                        s.note("  after 0.5 s: \(Int(hypot(frames.shown.minX - frames.place.minX, frames.shown.minY - frames.place.minY))) pt from its place  expect 0")
                    }
                }
            }),
            (1.0, "another icon size: the zones' icons spread out at once", {
                guard let view = mainView(), let fence = view.layout.fences.first(where: { $0.members.count >= 2 && !$0.collapsed }) else { s.note("  (no zone with 2 icons)"); return }
                let before = view.layout.iconSize
                let other: DesktopIconSize = before == .large ? .medium : .large
                view.debugSetIconSize(other)
                let a = view.debugCenter(of: fence.members[0]) ?? .zero, b = view.debugCenter(of: fence.members[1]) ?? .zero
                let apart = abs(b.x - a.x) > 1 ? abs(b.x - a.x) : abs(b.y - a.y)
                let cell = abs(b.x - a.x) > 1 ? view.debugFenceCellWidth : view.debugFenceCellHeight
                s.note("  \(other): icons in the zone \(Int(apart)) pt apart, a cell is \(Int(cell))  expect the same")
                view.debugSetIconSize(before)
            }),
            (1.0, "files dropped from another folder, not arrived yet: kept in the zone", {
                guard let view = mainView(), var fence = view.layout.fences.first else { return }
                let present = Set(((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? []).filter { !$0.hasPrefix(".") })
                // Two files on their way, one that isn't (a leftover)
                view.layout.expect(["on its way 1.txt", "on its way 2.txt"])
                for name in ["on its way 1.txt", "on its way 2.txt", "never coming.txt"] {
                    view.layout.setPlace(DesktopLayout.Place(point: CGPoint(x: 0.5, y: 0.5), screenID: fence.screenID), for: name)
                    fence.members.append(name)
                }
                view.layout.setFence(fence)
                // The desktop is read again before they arrive (another monitor, the first file landing)
                view.layout.prune(keeping: present)
                let members = view.layout.fences.first { $0.id == fence.id }?.members ?? []
                s.note("  still in the zone: \(members.contains("on its way 1.txt") && members.contains("on its way 2.txt")), place kept: \(view.layout.place(for: "on its way 1.txt") != nil), the other dropped: \(!members.contains("never coming.txt"))  expect true, true, true")
                fence.members.removeAll { $0.hasPrefix("on its way") || $0 == "never coming.txt" }
                view.layout.setFence(fence)
            }),
            (1.0, "a zone dragged near a row of cells snaps right beside it", {
                guard let view = mainView(), let fence = view.layout.fences.first, let fenceView = view.debugFenceView(fence.id),
                      let name = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                        .first(where: { n in !n.hasPrefix(".") && !view.layout.fences.contains { $0.members.contains(n) } && view.debugCenter(of: n) != nil }),
                      let probeCell = view.debugCellBelow(NSRect(x: 600, y: 300, width: 300, height: 0)) else { return }
                // The zone's bottom 6 pt into the icon of the cell below it
                let cellIconTop = probeCell.y - view.layout.iconSize.iconSide / 2
                var rect = fenceView.frame
                rect.origin = NSPoint(x: probeCell.x - rect.width / 2, y: cellIconTop + 6 - rect.height)
                let snapped = fenceView.snap?(rect, [.minX, .maxX, .minY, .maxY]).0 ?? rect
                view.debugSetFenceFrame(fence.id, snapped)
                // An icon put in that cell: stays there (the zone doesn't take the cell)
                view.debugPlace(name, at: probeCell)
                let at = view.debugCenter(of: name) ?? .zero
                s.note("  zone bottom moved up \(Int(rect.maxY - snapped.maxY)) pt; the cell under it is free: \(abs(at.x - probeCell.x) < 1 && abs(at.y - probeCell.y) < 1)  expect a few pt, true")
            }),
            (1.0, "zones on the icon grid, and off it again", {
                guard let view = mainView() else { return }
                FenceStyle.onGrid = true
                view.displayIfNeeded()
                let ids = view.layout.fences.filter { !$0.collapsed }.map(\.id)
                s.note("  on the grid: \(ids.filter(view.debugFenceOnGrid).count) of \(ids.count)  expect all")
                let stored = view.layout.fences.map(\.frame)
                FenceStyle.onGrid = false
                view.displayIfNeeded()
                let shown = view.layout.fences.compactMap { view.debugFenceFrames[$0.id] }
                s.note("  off: shown where stored: \(zip(stored, shown).allSatisfy { abs($0.minX - $1.minX) < 1 && abs($0.minY - $1.minY) < 1 })  expect true")
                FenceStyle.onGrid = true
            }),
            (1.0, "an icon dragged out of a zone onto the desktop", {
                guard let view = mainView(), let fence = view.layout.fences.first(where: { !$0.members.isEmpty }),
                      let name = fence.members.first, let spot = view.debugEmptySpot(NSSize(width: 200, height: 200)) else { s.note("  (no zone with icons)"); return }
                view.debugDrop(name, at: NSPoint(x: spot.midX, y: spot.midY))
                view.displayIfNeeded()
                s.note("  out of the zone: \(!(view.layout.fences.first { $0.id == fence.id }?.members.contains(name) ?? true)), shown: \(view.debugIconShown(name))  expect true, true")
            }),
            (1.0, "an icon put on another's place stays where it went", {
                guard let view = mainView() else { return }
                // Two loose icons (not in a zone): the later one alphabetically gives way
                let loose = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                    .filter { name in !name.hasPrefix(".") && !view.layout.fences.contains { $0.members.contains(name) } && view.debugCenter(of: name) != nil }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                guard loose.count >= 2, let spot = view.debugCenter(of: loose[0]), let free = view.debugEmptySpot(NSSize(width: 120, height: 120)) else {
                    s.note("  (not enough icons: \(loose.count), first at \(loose.first.flatMap { view.debugCenter(of: $0) }.map { "\($0)" } ?? "nil"), free spot: \(view.debugEmptySpot(NSSize(width: 120, height: 120)) != nil))")
                    return
                }
                let other = loose[loose.count - 1]
                view.debugPlace(other, at: spot)
                func distance(_ a: CGPoint?, _ b: CGPoint?) -> Int {
                    guard let a, let b else { return -1 }
                    return Int(hypot(a.x - b.x, a.y - b.y))
                }
                // One of the two stays on the spot, the other gives way
                let (stayer, mover) = distance(view.debugCenter(of: other), spot) < 5 ? (other, loose[0]) : (loose[0], other)
                let shown = view.debugCenter(of: mover)
                // The one on the spot leaves (as if deleted): the spot frees up
                view.debugPlace(stayer, at: NSPoint(x: free.midX, y: free.midY))
                let after = view.debugCenter(of: mover)
                s.note("  gave way: \(distance(shown, spot)) pt from the taken spot; after the spot freed: moved \(distance(shown, after)) pt  expect > 0, 0")
            }),
            (1.0, "select an empty area: «Создать зону здесь»", {
                guard let view = mainView(), let window = view.window, let spot = view.debugEmptySpot(NSSize(width: 260, height: 170)) else { s.note("  (no empty spot)"); return }
                // A real drag: down, dragged, up (in view coordinates → window)
                func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                let start = NSPoint(x: spot.minX + 10, y: spot.minY + 10), end = NSPoint(x: spot.maxX - 10, y: spot.maxY - 10)
                if let down = event(.leftMouseDown, start) { view.mouseDown(with: down) }
                if let drag = event(.leftMouseDragged, end) { view.mouseDragged(with: drag) }
                if let up = event(.leftMouseUp, end) { view.mouseUp(with: up) }
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let before = view.layout.fences.count
                s.note("  hint: «\(view.debugHintTitle)»  expect «\(L("Пустая зона на месте выделенной области"))»")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-4"), atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    view.debugClickHint()
                    s.note("  zones: \(before) → \(view.layout.fences.count), new one empty: \(view.layout.fences.last?.members.isEmpty == true)  expect +1, true")
                }
            }),
            (1.5, "style: square red corners", {
                FenceStyle.cornerRadius = 0
                FenceStyle.color = "#8B2E2E"
                FenceStyle.opacity = 0.8
                if let view = mainView(), let fence = view.layout.fences.last {
                    view.debugSetColor(fence.id, "#1C3D6E")
                    s.note("  own colour on screen: \(view.debugFenceView(fence.id)?.fence.color ?? "-")  expect #1C3D6E")
                }
                if let window = mainView()?.window {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-5"), atomically: true, encoding: .utf8)
                    }
                }
            }),
            (2.5, "done", { controller.hide() }),
        ])
    }

    /// A folder portal on the desktop (a sandbox folder), then quick-hide by double-click and back.
    static func portal(_ s: Scenario) {
        let folder = s.makeFiles(["Отчёт.txt", "План.md", "Бюджет.csv"], in: "Портал")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Вложенная"), withIntermediateDirectories: true)
        let controller = DesktopController()
        controller.show()
        func mainView() -> DesktopView? {
            NSApp.windows.lazy.compactMap { $0.contentView as? DesktopView }.first { $0.window?.screen == NSScreen.screens.first }
        }
        s.run([
            (2.0, "portal", {
                guard let view = mainView(), let id = view.debugMakePortal(folder, at: NSPoint(x: 420, y: 160)) else { s.note("  (no desktop)"); return }
                view.needsDisplay = true
                view.displayIfNeeded()
                let portal = view.debugFenceView(id)?.portalView
                s.note("  portal view: \(portal != nil)  expect true")
                if let window = view.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
            }),
            (1.5, "items read", {
                guard let view = mainView(), let fence = view.layout.fences.last else { return }
                s.note("  items in the portal: \(view.debugFenceView(fence.id)?.portalView?.itemCount ?? -1)  expect 4")
                try? "внутри".write(to: folder.appendingPathComponent("Вложенная/файл.txt"), atomically: true, encoding: .utf8)
                view.debugFenceView(fence.id)?.portalView?.show(folder.appendingPathComponent("Вложенная"))
            }),
            (1.0, "inside a subfolder", {
                guard let view = mainView(), let fence = view.layout.fences.last, let portal = view.debugFenceView(fence.id)?.portalView else { return }
                s.note("  in \(portal.currentFolder.lastPathComponent), \(portal.itemCount) item(s), can go up: \(portal.canGoUp)  expect Вложенная, 1, true")
                if let window = view.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-1"), atomically: true, encoding: .utf8)
                }
                portal.show(URL(fileURLWithPath: "/tmp"))  // outside the portal: refused (opens a window instead)
                s.note("  outside stays inside: \(portal.currentFolder.lastPathComponent)  expect Вложенная")
                AppDelegate.shared.windowControllers.last?.window?.close()
            }),
            (2.0, "go up", {
                guard let view = mainView(), let fence = view.layout.fences.last else { return }
                view.debugFenceView(fence.id)?.portalView?.goUp()
                if let window = view.window {
                    try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-2"), atomically: true, encoding: .utf8)
                }
            }),
            (2.0, "back up", {
                guard let view = mainView(), let fence = view.layout.fences.last, let portal = view.debugFenceView(fence.id)?.portalView else { return }
                s.note("  back in \(portal.currentFolder.lastPathComponent), can go up: \(portal.canGoUp)  expect Портал, false")
                if let image = controller.previewImage(), let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: s.output.appendingPathComponent("preview.png"))
                    s.note("  preview \(Int(image.size.width))×\(Int(image.size.height))")
                }
                // Snapshots: take, change, restore
                DesktopSnapshots.take(automatic: false)
                let before = view.layout.fences.count
                view.layout.fences = []
                if let snapshot = DesktopSnapshots.all.last { DesktopSnapshots.restore(snapshot, saveCurrent: true) }
                controller.reloadLayout()  // (the app's own desktop is reloaded by the restore; this one is the scenario's)
                s.note("  snapshots: \(DesktopSnapshots.all.count), fences after restore: \(mainView()?.layout.fences.count ?? -1)  expect 2, \(before)")
                // Restoring without saving: no new snapshot
                if let snapshot = DesktopSnapshots.all.last { DesktopSnapshots.restore(snapshot, saveCurrent: false) }
                s.note("  after restoring without saving: \(DesktopSnapshots.all.count)  expect 2")
                // One with a picture, then Settings ▸ Снимки shows them
                DesktopSnapshots.take(automatic: false, preview: controller.previewImage())
                controller.reloadLayout()
                AppDelegate.shared.showSettings(tab: .fences)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let window = NSApp.windows.first(where: { $0.contentViewController is NSTabViewController }) {
                        try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-3"), atomically: true, encoding: .utf8)
                    }
                }
            }),
            (2.0, "close settings", { NSApp.windows.first(where: { $0.contentViewController is NSTabViewController })?.close() }),
            (1.0, "quick-hide", {
                guard let view = mainView() else { return }
                try? FileManager.default.removeItem(at: DesktopSnapshots.folder)
                view.setQuickHidden(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let fence = view.layout.fences.last.flatMap { view.debugFenceView($0.id) }
                    s.note("  hidden: \(view.quickHidden), fence alpha \(fence?.alphaValue ?? -1)  expect true, 0")
                    view.setQuickHidden(false)
                }
            }),
            (1.2, "back", {
                guard let view = mainView() else { return }
                let fence = view.layout.fences.last.flatMap { view.debugFenceView($0.id) }
                s.note("  shown: \(!view.quickHidden), fence alpha \(fence?.alphaValue ?? -1)  expect true, 1")
                controller.hide()
            }),
        ])
    }

    /// A drag that isn't one: its pasteboard carries files or a sidebar favourite.
    final class FakeDrag: NSObject, NSDraggingInfo {
        let draggingPasteboard = NSPasteboard.withUniqueName()
        @MainActor init(urls: [URL] = [], favorite: String? = nil) {
            super.init()
            if let favorite {
                let item = NSPasteboardItem()
                item.setString(favorite, forType: .init("dev.winex.sidebar-favorite"))
                draggingPasteboard.writeObjects([item])
            } else {
                draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
            }
        }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .link, .generic] }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// Opens a file's context menu and hands its window to scripts/capture-window.sh contextmenu.
    static func contextMenu(_ s: Scenario) {
        let base = s.makeFiles(["отчёт.docx", "заметки.txt"])
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let table = s.table, let menu = table.menu, let window = table.window else { s.note("  (no table)"); s.run([]); return }
            s.select("отчёт.docx")
            let row = table.selectedRow
            let point = table.convert(NSPoint(x: 80, y: table.rect(ofRow: max(row, 0)).midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            // While the menu tracks, timers in the common modes still fire: find the menu's window,
            // let the script photograph it, then close the menu
            let find = Timer(timeInterval: 0.6, repeats: false) { _ in
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                // The context menu itself: menu level, the tallest (a submenu may be open beside it)
                let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) == 101 }
                func height(_ info: [String: Any]) -> CGFloat {
                    (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.height ?? 0
                }
                if let number = mine.max(by: { height($0) < height($1) })?[kCGWindowNumber as String] as? Int {
                    try? "\(number)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                }
                s.note("  menu items: \(menu.items.filter { !$0.isSeparatorItem }.map { $0.view != nil ? "[row]" : $0.title + ($0.image == nil ? "" : "🖼") }.prefix(9))")
                let close = Timer(timeInterval: 0.2, repeats: true) { timer in
                    if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-0").path) {
                        timer.invalidate()
                        menu.cancelTracking()
                    }
                }
                RunLoop.main.add(close, forMode: .common)
            }
            RunLoop.main.add(find, forMode: .common)
            // WINEX_MENU_TEST=N: highlight the N-th item with the keyboard (↓ × N) for the picture
            if let downs = Int(ProcessInfo.processInfo.environment["WINEX_MENU_TEST"] ?? ""), downs > 0 {
                let highlight = Timer(timeInterval: 0.3, repeats: false) { _ in
                    let arrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
                    for _ in 0..<downs {
                        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: 0, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                                                       isARepeat: false, keyCode: 125) {
                            NSApp.postEvent(down, atStart: false)
                        }
                    }
                }
                RunLoop.main.add(highlight, forMode: .common)
            }
            // A real right-click on the row (the table records it as the clicked row)
            table.rightMouseDown(with: event)
            s.run([])
        }
    }

    /// A big archive: the extraction window with its percentage (scripts/capture-window.sh unzip).
    static func unzip(_ s: Scenario) {
        let source = s.makeFiles([], in: "big")
        let chunk = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for i in 1...1500 { FileManager.default.createFile(atPath: source.appendingPathComponent("file-\(i).bin").path, contents: chunk) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", source.path, s.sandbox.appendingPathComponent("big.zip").path]
        try? zip.run()
        zip.waitUntilExit()
        try? FileManager.default.removeItem(at: source)
        s.note("  archive: \(s.files())")
        FileCommands.extract(s.sandbox.appendingPathComponent("big.zip"))
        func wait(_ tries: Int) {
            if let window = NSApp.windows.first(where: { $0.isVisible && ($0.title.contains("%") || $0.title.contains("Подготовка")) }) {
                s.note("  window: \(window.title)")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { s.run([]) }   // lets the extraction finish
                return
            }
            guard tries > 0 else { s.note("  (no progress window — too fast?)"); s.run([]); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { wait(tries - 1) } }
        }
        wait(60)
    }

    /// ⌘C then ⌘V as real key presses (through the window, like the keyboard), in the table and
    /// in the icon view, before and after a context menu was built.
    static func pasteKeys(_ s: Scenario) {
        let base = s.makeFiles(["a.txt"])
        s.window?.navigate(to: base)
        func press(_ key: String, _ code: UInt16) { s.key(key, code: code, modifiers: .command) }
        s.run([
            (0.6, "table: ⌘C ⌘V", { s.setViewMode(.details); s.select("a.txt"); press("c", 8); press("v", 9) }),
            (1.0, "result", { s.note("  \(s.files())  expect a - копия.txt") }),
            (0.2, "open and close the context menu, then ⌘V", {
                if let table = s.table, let menu = table.menu { menu.delegate?.menuNeedsUpdate?(menu) }
                s.select("a.txt"); press("c", 8); press("v", 9)
            }),
            (1.0, "result", { s.note("  \(s.files())  expect a - копия (2).txt") }),
            (0.2, "icons: ⌘C ⌘V", {
                s.setViewMode(.mediumIcons)
                s.select("a.txt")
                let responder = s.window?.window?.firstResponder
                let pasteTarget = NSApp.target(forAction: #selector(NSText.paste(_:)))
                s.note("  first responder: \(responder.map { "\(type(of: $0))" } ?? "-"), paste goes to: \(pasteTarget.map { "\(type(of: $0))" } ?? "-"), selected: \(s.selectedNames)")
                press("c", 8)
                s.note("  clipboard after ⌘C: \(NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])")
                press("v", 9)
            }),
            (1.0, "result", { s.note("  \(s.files())  expect a third copy") }),
            (0.2, "icons: ⌘V through the main menu directly", {
                s.select("a.txt")
                s.key("v", code: 9, modifiers: .command, viaMenu: true)
            }),
            (1.0, "result", { s.note("  \(s.files())  (main menu path)") }),
            (0.2, "focus in the sidebar (after a click there), then ⌘V", {
                if let outline = s.find(NSOutlineView.self, in: s.window?.window?.contentView) { s.window?.window?.makeFirstResponder(outline) }
                s.note("  paste goes to: \(NSApp.target(forAction: #selector(NSText.paste(_:))).map { "\(type(of: $0))" } ?? "nobody")")
                press("v", 9)
            }),
            (1.0, "result", { s.note("  \(s.files())  expect one more copy") }),
            (0.2, "who swallows ⌘V in the window?", {
                guard let window = s.window?.window,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) else { return }
                @MainActor func walk(_ view: NSView, _ depth: Int) {
                    for sub in view.subviews where !sub.isHiddenOrHasHiddenAncestor {
                        if sub.performKeyEquivalent(with: event) { s.note("  handled by \(type(of: sub)) (depth \(depth))"); return }
                        walk(sub, depth + 1)
                    }
                }
                if let content = window.contentView { walk(content, 0) }
            }),
            (1.0, "result", { s.note("  \(s.files())") }),
        ])
    }

    /// A window to photograph (scripts/capture-window.sh look): two tabs, some files, the icon view.
    static func look(_ s: Scenario) {
        let base = s.makeFiles(["Документы/", "Проекты/", "отчёт.pdf", "заметки.txt", "фото.png", "таблица.xlsx", "xiaomi vacuum 5 pro token.rtf"])
        s.window?.navigate(to: base)
        s.window?.addTab(url: FileManager.default.homeDirectoryForCurrentUser, select: false)
        s.window?.window?.setFrame(NSRect(x: 200, y: 200, width: 1000, height: 620), display: true)
        NSApp.activate(ignoringOtherApps: true)
        s.window?.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = s.window?.window else { s.run([]); return }
            s.note("  view: \(ViewMode.saved.title)")
            let sidebar = s.find(NSOutlineView.self, in: window.contentView)?.enclosingScrollView?.superview
            s.note("  sidebar width: \(Int(sidebar?.frame.width ?? -1))  expect 200")
            // Finder-style selection: a folder and a long name
            if let grid = s.grid {
                let names = (0..<grid.count).map { (grid.item(at: IndexPath(item: $0, section: 0)) as? FileGridItem)?.textField?.stringValue ?? "" }
                let picked = IndexSet(names.indices.filter { names[$0] == "Проекты" || names[$0].hasPrefix("xiaomi") })
                grid.setSelection(picked, anchor: picked.first ?? 0)
                window.makeFirstResponder(grid)
                if ProcessInfo.processInfo.environment["WINEX_MENU_TEST"] == "rename" {
                    let one = IndexSet(names.indices.filter { names[$0] == "таблица.xlsx" })
                    grid.setSelection(one, anchor: one.first ?? 0)
                    s.send("renameSelected:")
                }
            }
            try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-0"), atomically: true, encoding: .utf8)
            @MainActor func wait(_ tries: Int) {
                if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-0").path) || tries == 0 { s.run([]); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { wait(tries - 1) } }
            }
            wait(50)
        }
    }

    /// Run by scripts/check-self-update.sh on a copy of the app: updates itself from a local feed.
    static func selfUpdate(_ s: Scenario) {
        s.note("  running \(Updater.shared.currentVersion) from \(Bundle.main.bundlePath)")
        Updater.shared.check(userInitiated: true)
        // The update quits this process; if it doesn't within 20 s, say so
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { s.note("  (still running — no update happened)"); s.run([]) }
    }

    /// The relaunched copy after "selfupdate": reports its version and quits.
    static func updated(_ s: Scenario) {
        s.note("  after the update: \(Updater.shared.currentVersion) from \(Bundle.main.bundlePath)")
        s.run([])
    }

    /// Opens Settings and shows each tab in turn, waiting for an outside `screencapture -l` of the
    /// window (writes <out>/tab-N with the window number, waits for <out>/shot-N).
    static func settingsTabs(_ s: Scenario) {
        AppDelegate.shared.showSettings(nil)
        if let only = ProcessInfo.processInfo.environment["WINEX_SETTINGS_TAB"].flatMap(Int.init),
           let tab = SettingsWindowController.Tab(rawValue: only) { AppDelegate.shared.showSettings(tab: tab) }
        func tabs() -> NSTabViewController? { NSApp.windows.first { $0.title.hasPrefix("Настройки") || $0.contentViewController is NSTabViewController }?.contentViewController as? NSTabViewController }
        @MainActor func step(_ index: Int) {
            guard let tabs = tabs(), let window = tabs.view.window else { s.note("  (no settings window)"); s.run([]); return }
            guard index < tabs.tabViewItems.count else { window.close(); s.run([]); return }
            tabs.selectedTabViewItemIndex = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                s.note("  \(tabs.tabViewItems[index].label): \(Int(window.frame.width))×\(Int(window.frame.height))")
                try? "\(window.windowNumber)".write(to: s.output.appendingPathComponent("tab-\(index)"), atomically: true, encoding: .utf8)
                @MainActor func wait(_ tries: Int) {
                    if FileManager.default.fileExists(atPath: s.output.appendingPathComponent("shot-\(index)").path) || tries == 0 { step(index + 1); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { wait(tries - 1) }
                }
                wait(50)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step(0) }
    }

    /// The updater's download and signature check (without the restart): a build signed with our
    /// certificate is accepted, an ad-hoc copy is refused. Uses this very app as the "release".
    static func update(_ s: Scenario) {
        let fm = FileManager.default
        let good = s.sandbox.appendingPathComponent("WinEx.app")
        let forged = s.sandbox.appendingPathComponent("forged/WinEx.app")
        try? fm.createDirectory(at: forged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: Bundle.main.bundleURL, to: good)
        try? fm.copyItem(at: Bundle.main.bundleURL, to: forged)
        func shell(_ command: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            try? process.run()
            process.waitUntilExit()
        }
        shell("codesign --force --sign - '\(forged.path)' 2>/dev/null")
        shell("cd '\(s.sandbox.path)' && ditto -c -k --keepParent WinEx.app good.zip && cd forged && ditto -c -k --keepParent WinEx.app ../forged.zip")
        s.note("  running app signed with a certificate: \(Updater.isSignedLikeUs(Bundle.main.bundleURL))")
        Task { @MainActor in
            // The latest real release from GitHub, as the updater would get it
            if let url = URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest"),
               let data = try? await URLSession.shared.data(from: url).0,
               let release = try? JSONDecoder().decode(Updater.Release.self, from: data), let asset = release.archive,
               let app = try? await Updater.shared.download(asset.browser_download_url) {
                s.note("  GitHub \(release.tag_name): \(asset.name) → accepted: \(Updater.isSignedLikeUs(app))  expect true")
            } else {
                s.note("  (no release on GitHub)")
            }
            for name in ["good", "forged"] {
                do {
                    let app = try await Updater.shared.download(s.sandbox.appendingPathComponent("\(name).zip"))
                    s.note("  \(name).zip → \(app.lastPathComponent), accepted: \(Updater.isSignedLikeUs(app))  expect \(name == "good")")
                } catch {
                    s.note("  \(name).zip: \(error.localizedDescription)")
                }
            }
            s.run([])
        }
    }

    /// Can this build read the Trash (Full Disk Access)? Launch with `open` so that macOS checks
    /// WinEx itself, not the terminal that started it.
    static func trashAccess(_ s: Scenario) {
        s.run([
            (0.2, "read ~/.Trash", {
                do {
                    let items = try FileManager.default.contentsOfDirectory(atPath: Places.trashURL.path)
                    s.note("  ok: \(items.count) items")
                } catch {
                    s.note("  error: \(error.localizedDescription)")
                }
                // Granted once with the persistent signature: this build must read it without asking
                let desktop = (try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path))?.count
                s.note("  Desktop: \(desktop.map { "ok, \($0) items" } ?? "no access")")
            }),
        ])
    }

    /// "Этот Mac", empty-folder and Trash messages, the size of the selection, the start folder.
    static func drives(_ s: Scenario) {
        let base = s.makeFiles(["dir/", "empty/"])
        FileManager.default.createFile(atPath: base.appendingPathComponent("big.bin").path, contents: Data(count: 3_000_000))
        FileManager.default.createFile(atPath: base.appendingPathComponent("dir/inner.bin").path, contents: Data(count: 1_000_000))
        func status() -> String {
            s.window?.statusText ?? "?"
        }
        func message() -> String {
            guard let view = (s.window?.window?.contentView).flatMap({ s.find(EmptyStateView.self, in: $0) }), !view.isHidden else { return "-" }
            return s.findAll(NSTextField.self, in: view).map(\.stringValue).filter { !$0.isEmpty }.joined(separator: " | ")
        }
        s.run([
            (0.8, "Этот Mac", { s.window?.navigate(to: Places.computerURL) }),
            (1.5, "drives", {
                s.note("  \(s.window?.selectedTab.title ?? "?"): \(status())")
                guard let drives = (s.window?.window?.contentView).flatMap({ s.find(DrivesView.self, in: $0) }) else { return }
                let data = drives.dataWithPDF(inside: drives.bounds)
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: s.output.appendingPathComponent("drives.png"))
                }
            }),
            (0.2, "an empty folder", { s.window?.navigate(to: base.appendingPathComponent("empty")) }),
            (0.8, "message", { s.note("  \(message())  expect Эта папка пуста") }),
            (0.2, "the Trash", { s.window?.navigate(to: Places.trashURL) }),
            (0.8, "message", { s.note("  \(message())") }),
            (0.2, "select big.bin and dir", {
                s.window?.navigate(to: base)
                s.setViewMode(.details)
            }),
            (0.8, "selection", {
                guard let table = s.table else { return }
                let rows = (0..<table.numberOfRows).filter { ["big.bin", "dir"].contains((table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? "") }
                table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
                s.note("  right away: \(status())")
            }),
            (1.0, "counted", { s.note("  later: \(status())  expect 4 MB") }),
            (0.2, "start folder: Рабочий стол", {
                Settings.startFolder = "desktop"
                AppDelegate.shared.newWindow(nil)
                s.note("  new window: \(AppDelegate.shared.windowControllers.last?.selectedTab.title ?? "?")  expect Рабочий стол / Desktop")
                Settings.startFolder = "home"
            }),
            (0.3, "the start folder menu in Settings", {
                AppDelegate.shared.showSettings(nil)
                let window = NSApp.windows.first { $0.title == "Настройки WinEx" }
                let popups = (window?.contentView).map { s.findAll(NSPopUpButton.self, in: $0) } ?? []
                let start = popups.first { $0.itemTitles.contains("Рабочий стол") }
                s.note("  items: \(start?.itemTitles ?? [])  selected: \(start?.titleOfSelectedItem ?? "-")")
                window?.close()
            }),
        ])
    }

    /// Duplicate, compress, extract (double-click), alias (open, show original), package contents,
    /// Windows keys, the global shortcut's registration.
    static func fileCommands(_ s: Scenario) {
        let base = s.makeFiles(["a.txt", "dir/", "Pkg.app/", "Pkg.app/Contents/"])
        s.makeFiles(["inner.txt"], in: "dir")
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        func open(_ name: String) {
            s.select(name)
            s.send("openSelected:")
        }
        s.run([
            (0.8, "duplicate a.txt", { s.select("a.txt"); s.send("duplicate:") }),
            (0.8, "compress a.txt, then a.txt + dir", {
                s.note("  \(s.files())  expect a - копия.txt")
                s.select("a.txt"); s.send("compress:")
            }),
            (1.0, "compress two", {
                s.table?.selectRowIndexes(IndexSet((0..<(s.table?.numberOfRows ?? 0)).filter { row in
                    ["a.txt", "dir"].contains((s.table?.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? "")
                }), byExtendingSelection: false)
                s.send("compress:")
            }),
            (1.5, "double-click Архив.zip", {
                s.note("  \(s.files())  expect a.txt.zip, Архив.zip")
                // A file compressed alone holds just the file, not its parent folder
                let list = Process()
                list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
                list.arguments = ["-1", base.appendingPathComponent("a.txt.zip").path]
                let pipe = Pipe()
                list.standardOutput = pipe
                try? list.run()
                list.waitUntilExit()
                let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n").filter { !$0.hasPrefix("__MACOSX") }
                s.note("  a.txt.zip holds: \(entries)  expect [a.txt]")
                open("Архив.zip")
            }),
            (1.5, "extracted", {
                s.note("  \(s.files())  expect folder Архив")
                s.note("  Архив: \(s.files(in: base.appendingPathComponent("Архив")))  expect a.txt, dir")
            }),
            (0.2, "alias of dir", { s.select("dir"); s.send("makeAlias:") }),
            (0.8, "open the alias", {
                let alias = base.appendingPathComponent("dir псевдоним")
                s.note("  alias: \(FileCommands.isAlias(alias)), points to: \(FileCommands.original(of: alias)?.lastPathComponent ?? "-")")
                open("dir псевдоним")
            }),
            (0.8, "where are we", {
                s.note("  \(s.window?.selectedTab.title ?? "?")  expect dir")
                s.window?.goBack(nil)
            }),
            (0.8, "show package contents", { s.select("Pkg.app"); s.send("showPackageContents:") }),
            (0.8, "inside the package", {
                s.note("  \(s.window?.selectedTab.title ?? "?") → \(s.names())  expect Pkg, [Contents]")
            }),
            (0.2, "Windows keys: ⌥← back, ⌃Tab with two tabs", {
                Settings.windowsKeys = true
                s.window?.window?.makeFirstResponder(s.table)
                s.key("", code: 123, modifiers: .option)
            }),
            (0.6, "after ⌥←", {
                s.note("  \(s.window?.selectedTab.title ?? "?")  expect the sandbox folder")
                s.window?.newTab(nil)
            }),
            (0.5, "⌃1", {
                s.key("1", code: 18, modifiers: .control)
                s.note("  tab \((s.window?.selectedIndex ?? -1) + 1) of \(s.window?.tabs.count ?? 0)  expect 1 of 2")
                s.key("\t", code: 48, modifiers: .control)
                s.note("  after ⌃Tab: tab \((s.window?.selectedIndex ?? -1) + 1)  expect 2")
                Settings.windowsKeys = false
            }),
            (0.2, "global shortcut registers", {
                GlobalHotKey.preset = .controlOptionE
                GlobalHotKey.shared.apply()
                s.note("  ⌃⌥E registered: \(GlobalHotKey.shared.isRegistered)")
                GlobalHotKey.preset = .off
                GlobalHotKey.shared.apply()
            }),
        ])
    }

    /// Search in a folder (not indexed by Spotlight: the name walk), back to the folder, the whole
    /// Mac; CPU while results are shown and after leaving them.
    static func search(_ s: Scenario) {
        let base = s.makeFiles(["Отчёт 2024.txt", "report.txt", "other.txt"])
        s.makeFiles(["отчет старый.md"], in: "sub/deep")
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        func field() -> NSSearchField? { s.find(NSSearchField.self, in: s.window?.window?.contentView) }
        func type(_ text: String) {
            guard let field = field(), let action = field.action else { s.note("  (no search field)"); return }
            field.stringValue = text
            NSApp.sendAction(action, to: field.target, from: field)
        }
        func status() -> String {
            (s.window?.window?.contentView).map { v in s.findAll(NSTextField.self, in: v) }?
                .first { $0.stringValue.hasPrefix("Найдено") || $0.stringValue.contains("элемент") || $0.stringValue.hasPrefix("Введите") }?.stringValue ?? "?"
        }
        func names() -> [String] {
            guard let table = s.table else { return [] }
            return (0..<table.numberOfRows).compactMap { (table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue }.sorted()
        }
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        var cpuStart = 0.0
        Settings.searchWholeMac = false
        s.run([
            (0.8, "type «отчёт»", { type("отчёт") }),
            (2.5, "results", {
                s.note("  \(s.window?.selectedTab.title ?? "?") | \(status())")
                s.note("  \(names())  expect Отчёт 2024.txt, отчет старый.md")
                let folderColumn = s.table?.tableColumn(withIdentifier: .init("folder"))
                s.note("  folder column shown: \(folderColumn?.isHidden == false)")
                cpuStart = cpuSeconds()
            }),
            (5.0, "CPU with results on screen (5 s)", { s.note(String(format: "  %.1f%% of one core", (cpuSeconds() - cpuStart) / 5 * 100)) }),
            (0.1, "clear the field", { type("") }),
            (0.8, "back in the folder", {
                s.note("  \(s.window?.selectedTab.title ?? "?"), folder column hidden: \(s.table?.tableColumn(withIdentifier: .init("folder"))?.isHidden == true)")
                cpuStart = cpuSeconds()
            }),
            (5.0, "CPU after leaving the results (5 s)", { s.note(String(format: "  %.1f%% of one core", (cpuSeconds() - cpuStart) / 5 * 100)) }),
            (0.1, "type again, then Esc", {
                type("отч")
            }),
            (1.0, "Esc", {
                s.window?.window?.makeFirstResponder(field())
                s.key("\u{1b}", code: 53)
            }),
            (0.6, "after Esc", {
                let focus = s.window?.window?.firstResponder
                s.note("  field: «\(field()?.stringValue ?? "?")», \(s.window?.selectedTab.title ?? "?"), focus in the list: \(focus === s.table || focus === s.grid)  expect «», the folder, true")
            }),
            (0.1, "whole Mac, 1 letter", { Settings.searchWholeMac = true; type("W") }),
            (0.8, "too short", { s.note("  \(status())") }),
            (0.1, "whole Mac: «WinEx»", {
                cpuStart = cpuSeconds()
                type("WinEx")
            }),
            (4.0, "results", {
                s.note("  \(status()), CPU for the search: \(String(format: "%.2f", cpuSeconds() - cpuStart)) s")
                s.note("  includes this project: \(names().contains("WinEx"))")
                Settings.searchWholeMac = false
            }),
        ])
    }

    /// Copy with the progress window (pause, resume), then a move with name clashes decided per file.
    static func fileOps(_ s: Scenario) {
        let fm = FileManager.default
        let from = s.makeFiles(["a.txt", "b.txt", "c.txt", "d.txt"], in: "from")
        let to = s.makeFiles([], in: "to")
        let target = s.makeFiles(["a.txt", "b.txt", "c.txt"], in: "target")
        let big = from.appendingPathComponent("big.bin")
        fm.createFile(atPath: big.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: big) {
            let chunk = Data(repeating: 0x5A, count: 8 << 20)
            for _ in 0..<40 { handle.write(chunk) }  // 320 MB
            try? handle.close()
        }
        FileOperation.cloneFiles = false
        FileOperation.slowDownForTesting = 0.012

        func window(titled test: (String) -> Bool) -> NSWindow? { NSApp.windows.first { $0.isVisible && test($0.title) } }
        var progressWindow: NSWindow? { window { $0.contains("%") || $0.contains("Подготовка") || $0.contains("Приостановлено") } }
        var conflictWindow: NSWindow? { window { $0 == "Замена или пропуск файлов" } }
        func texts(_ view: NSView?) -> [String] {
            guard let view else { return [] }
            var result: [String] = []
            if let field = view as? NSTextField, !field.stringValue.isEmpty { result.append(field.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { result.append("[\(button.title)]") }
            return result + view.subviews.flatMap(texts)
        }
        func snapshot(_ window: NSWindow?, _ name: String) {
            guard let view = window?.contentView else { return }
            let data = view.dataWithPDF(inside: view.bounds)
            guard let image = NSImage(data: data) else { return }
            let size = NSSize(width: view.bounds.width * 2, height: view.bounds.height * 2)
            let png = NSImage(size: size, flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill(); rect.fill()
                image.draw(in: rect)
                return true
            }
            guard let tiff = png.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: s.output.appendingPathComponent(name))
        }
        func press(_ title: String, in view: NSView?) -> Bool {
            guard let view else { return false }
            if let button = view as? NSButton, button.title == title || button.toolTip == title { button.performClick(nil); return true }
            return view.subviews.contains { press(title, in: $0) }
        }
        func waitUntil(_ condition: @escaping () -> Bool, then next: @escaping () -> Void, tries: Int = 300) {
            if condition() || tries == 0 { next(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitUntil(condition, then: next, tries: tries - 1) }
        }

        s.run([
            (0.3, "copy 320 MB", { FileOps.transfer([big], to: to, copy: true) }),
            (1.5, "progress window", {
                s.note("  \(progressWindow?.title ?? "(no progress window)")")
                s.note("  \(texts(progressWindow?.contentView).joined(separator: " | "))")
                snapshot(progressWindow, "progress.png")
            }),
            (0.1, "fewer / more details", {
                let full = progressWindow?.frame.height ?? 0
                _ = press("Меньше подробностей", in: progressWindow?.contentView)
                let small = progressWindow?.frame.height ?? 0
                _ = press("Больше подробностей", in: progressWindow?.contentView)
                s.note("  height: \(Int(full)) → \(Int(small)) → \(Int(progressWindow?.frame.height ?? 0))  expect smaller, then back")
            }),
            (0.1, "pause", { if !press("Приостановить", in: progressWindow?.contentView) { s.note("  (no pause button)") } }),
            (0.8, "paused?", {
                let first = progressWindow?.title ?? "-"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    s.note("  \(first) → \(progressWindow?.title ?? "-")  expect the same percentage (paused)")
                    snapshot(progressWindow, "paused.png")
                    // Full speed for the rest: the next steps expect the copy to be over
                    FileOperation.slowDownForTesting = 0
                    _ = press("Продолжить", in: progressWindow?.contentView)
                }
            }),
            (1.0, "wait for the copy", {
                waitUntil({ progressWindow == nil }) {
                    let size = (try? fm.attributesOfItem(atPath: to.appendingPathComponent("big.bin").path)[.size] as? Int) ?? 0
                    s.note("  copied: \(size / 1_048_576) MB, window gone: \(progressWindow == nil), undo: \(FileUndo.manager.undoActionName)")
                    FileOperation.slowDownForTesting = 0
                    // Move with clashes: a, b, c exist in target; d doesn't
                    FileOps.transfer(["a.txt", "b.txt", "c.txt", "d.txt"].map { from.appendingPathComponent($0) }, to: target, copy: false)
                }
            }),
            (1.5, "conflict dialog", {
                s.note("  \(texts(conflictWindow?.contentView).joined(separator: " | "))")
                snapshot(conflictWindow, "conflict.png")
                _ = press("Решить для каждого файла", in: conflictWindow?.contentView)
            }),
            (0.5, "decide for each", {
                snapshot(conflictWindow, "each.png")
                let popups = (conflictWindow?.contentView).map { v in s.findAll(NSPopUpButton.self, in: v) } ?? []
                // a: replace, b: skip, c: keep both
                for (popup, index) in zip(popups, [0, 1, 2]) { popup.selectItem(at: index) }
                s.note("  rows: \(popups.count), popups: \(popups.map { "\($0.convert($0.bounds, to: nil))" }), window: \(conflictWindow?.frame.size ?? .zero)")
                s.note("  \(texts(conflictWindow?.contentView).suffix(3).joined(separator: " | "))")
                _ = press("Продолжить", in: conflictWindow?.contentView)
            }),
            (1.0, "result", {
                s.note("  target: \(s.files(in: target))  expect a, b, c, c - копия, d")
                s.note("  from: \(s.files(in: from).filter { $0 != "big.bin" })  expect b (skipped)")
                FileOperation.cloneFiles = true
            }),
        ])
    }

    /// An icon whose monitor isn't connected shows on the main one; its place is kept for when the
    /// monitor comes back. (Pretends the second monitor's icons belong to a monitor that's gone.)
    static func monitorGone(_ s: Scenario) {
        let controller = DesktopController()
        controller.show()
        func views() -> [DesktopView] { NSApp.windows.compactMap { $0.contentView as? DesktopView } }
        func counts() -> String { views().forEach { $0.displayIfNeeded() }; return views().map { "\($0.window?.screen?.localizedName ?? "?"): \($0.subviews.count)" }.joined(separator: ", ") }
        var moved: [String] = []
        s.run([
            (1.5, "start", { s.note("  icons: \(counts())") }),
            (0.2, "second monitor's icons → a monitor that isn't connected", {
                guard let main = views().first(where: { $0.window?.screen == NSScreen.screens.first }),
                      let second = NSScreen.screens.dropFirst().first?.displayUUID else { s.note("  (one monitor only)"); return }
                let fm = FileManager.default
                let names = (try? fm.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? []
                for name in names {
                    guard let place = main.layout.place(for: name), place.screenID == second else { continue }
                    main.layout.setPlace(DesktopLayout.Place(point: place.point, screenID: "GONE"), for: name)
                    moved.append(name)
                }
                views().forEach { $0.reloadShared() }
                s.note("  moved \(moved.count); icons: \(counts())  expect all on the main monitor")
                let kept = moved.compactMap { main.layout.place(for: $0)?.screenID }
                s.note("  stored monitor kept: \(kept.allSatisfy { $0 == "GONE" } && !kept.isEmpty)")
                // Put them back (the layout lives in the scenario's own settings anyway)
                for name in moved {
                    if let place = main.layout.place(for: name) {
                        main.layout.setPlace(DesktopLayout.Place(point: place.point, screenID: second), for: name)
                    }
                }
                views().forEach { $0.reloadShared() }
                s.note("  back: \(counts())")
            }),
            (0.3, "set up on a laptop that's gone: a zone at its right edge, two icons at the top middle", {
                guard let main = views().first(where: { $0.window?.screen == NSScreen.screens.first }),
                      let here = NSScreen.screens.first?.frame.size else { return }
                let laptop = CGSize(width: 1200, height: 800)
                main.layout.debugSetSize(ofScreen: "LAPTOP", laptop)
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                    .filter { name in !name.hasPrefix(".") && !main.layout.fences.contains { $0.members.contains(name) } }.sorted().prefix(2)
                guard names.count == 2, let a = names.first, let b = names.last else { s.note("  (need 2 icons)"); return }
                let saved = names.map { main.layout.place(for: $0) }
                // Side by side, in the laptop's right half, next to where the zone is
                main.layout.setPlace(DesktopLayout.Place(point: CGPoint(x: 700 / laptop.width, y: 400 / laptop.height), screenID: "LAPTOP"), for: a)
                main.layout.setPlace(DesktopLayout.Place(point: CGPoint(x: 820 / laptop.width, y: 400 / laptop.height), screenID: "LAPTOP"), for: b)
                // A zone 10 pt from the laptop's right edge, 60 pt from its top
                let zone = DesktopFence(title: "Laptop", screenID: "LAPTOP", x: laptop.width - 10 - 300, y: 60, width: 300, height: 200)
                main.layout.setFence(zone)
                views().forEach { $0.reloadShared() }
                main.displayIfNeeded()
                let (ca, cb) = (main.debugCenter(of: a) ?? .zero, main.debugCenter(of: b) ?? .zero)
                let frame = main.debugFenceView(zone.id)?.frame ?? .zero
                // At the right edge as on the laptop if there's room; else moved, whole, beside what's there
                let under = main.debugIconsUnder(frame)
                s.note("  zone: \(Int(frame.width))×\(Int(frame.height)), \(Int(here.width - frame.maxX)) pt from the right edge, \(Int(frame.minY)) from the top, icons under it: \(under.count)  expect 300×200, 10 (or beside what's there), 60, 0")
                s.note("  icons: \(Int(cb.x - ca.x)) pt apart, \(Int(cb.y - ca.y)) pt higher/lower, in grid cells: \(main.debugOnGrid(a) && main.debugOnGrid(b))  expect 120, 0 (still side by side), true (grid on: \(main.layout.alignToGrid))")
                // Something moved here: the arrangement as shown here is the one to go by from now on
                let shownZone = main.debugFenceView(zone.id)?.frame ?? .zero
                let shownA = main.debugCenter(of: a) ?? .zero
                main.debugDrop(a, at: shownA)
                let thisMonitor = NSScreen.screens.first?.displayUUID ?? "?"
                let storedZone = main.layout.fences.first { $0.id == zone.id }
                s.note("  after a change here: zone on \(storedZone?.screenID == thisMonitor ? "this monitor" : storedZone?.screenID ?? "-") at its shown place: \(storedZone.map { abs($0.x - shownZone.minX) < 1 && abs($0.y - shownZone.minY) < 1 } ?? false); icons on \(main.layout.place(for: b)?.screenID == thisMonitor ? "this monitor" : main.layout.place(for: b)?.screenID ?? "-")  expect this monitor, true, this monitor")
                // Put things back
                var fences = main.layout.fences
                fences.removeAll { $0.id == zone.id }
                main.layout.fences = fences
                for (name, place) in zip(names, saved) { if let place { main.layout.setPlace(place, for: name) } }
                main.layout.debugSetSize(ofScreen: "LAPTOP", nil)
                views().forEach { $0.reloadShared() }
            }),
            (0.3, "a monitor WinEx never saw (only macOS remembers it): its zone keeps its edge", {
                guard let main = views().first(where: { $0.window?.screen == NSScreen.screens.first }),
                      let here = NSScreen.screens.first?.frame.size else { return }
                let connected = Set(NSScreen.screens.compactMap { $0.displayUUID?.uppercased() })
                guard let (id, size) = SystemDisplays.known.first(where: { !connected.contains($0.key) && $0.value != here }) else {
                    s.note("  (no disconnected monitor of another size remembered by macOS)"); return
                }
                main.layout.debugSetSize(ofScreen: id, nil)
                let zone = DesktopFence(title: "Unseen", screenID: id, x: size.width - 8 - 440, y: 42, width: 440, height: 279)
                main.layout.setFence(zone)
                views().forEach { $0.reloadShared() }
                main.displayIfNeeded()
                let frame = main.debugFenceView(zone.id)?.frame ?? .zero
                s.note("  \(id.prefix(8)) remembered as \(Int(size.width))×\(Int(size.height)); zone \(Int(here.width - frame.maxX)) pt from the right edge, \(Int(frame.minY)) from the top, icons under it: \(main.debugIconsUnder(frame).count)  expect 8 (or beside what's there), 42, 0")
                var fences = main.layout.fences
                fences.removeAll { $0.id == zone.id }
                main.layout.fences = fences
                views().forEach { $0.reloadShared() }
            }),
            (0.3, "this monitor at another resolution for a while (as when waking up)", {
                guard let main = views().first(where: { $0.window?.screen == NSScreen.screens.first }),
                      let id = NSScreen.screens.first?.displayUUID, let here = NSScreen.screens.first?.frame.size else { return }
                let real = main.layout.recordedSize(ofScreen: id)
                // Its places measured on 1200×800: a zone 10 pt from the right edge, 20 from the bottom
                let old = CGSize(width: 1200, height: 800)
                main.layout.setRecordedSize(old, ofScreen: id)
                let zone = DesktopFence(title: "Set up at 1200×800", screenID: id, x: old.width - 10 - 300, y: old.height - 20 - 200, width: 300, height: 200)
                main.layout.setFence(zone)
                main.layout.noteScreens(DesktopView.layoutScreens())
                views().forEach { $0.reloadShared() }
                main.displayIfNeeded()
                let frame = main.debugFenceView(zone.id)?.frame ?? .zero
                let stored = main.layout.fences.first { $0.id == zone.id }
                s.note("  shown \(Int(here.width - frame.maxX)) pt from the right edge; stored place kept: \(stored?.x == old.width - 310 && stored?.y == old.height - 220), measured on \(main.layout.recordedSize(ofScreen: id).map { "\(Int($0.width))×\(Int($0.height))" } ?? "-")  expect about 10 (beside what's there if needed), true, 1200×800")
                // A new file arrives (a picture saved from a browser): the zone stays where it's shown
                let icons = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                    .filter { name in !name.hasPrefix(".") && !main.layout.fences.contains { $0.members.contains(name) } }
                let placesBefore = Dictionary(icons.compactMap { name in main.layout.place(for: name).map { (name, $0) } }, uniquingKeysWith: { a, _ in a })
                if let newcomer = icons.first {
                    main.layout.debugForgetPlace(of: newcomer)
                    views().forEach { $0.reloadShared() }
                    main.displayIfNeeded()
                    let after = main.debugFenceView(zone.id)?.frame ?? .zero
                    s.note("  a new file appears: zone moved \(Int(after.minX - frame.minX)),\(Int(after.minY - frame.minY)); measured on \(main.layout.recordedSize(ofScreen: id).map { "\(Int($0.width))×\(Int($0.height))" } ?? "-")  expect 0,0 and this monitor's size \(Int(here.width))×\(Int(here.height))")
                    for (name, place) in placesBefore { main.layout.setPlace(place, for: name) }
                }
                var fences = main.layout.fences
                fences.removeAll { $0.id == zone.id }
                main.layout.fences = fences
                if let real { main.layout.setRecordedSize(real, ofScreen: id) }
                main.layout.save()
                views().forEach { $0.reloadShared() }
            }),
            (0.2, "an old «main monitor» place on top of an icon that lives there", {
                guard let main = views().first(where: { $0.window?.screen == NSScreen.screens.first }),
                      let id = NSScreen.screens.first?.displayUUID else { return }
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? [])
                    .filter { !$0.hasPrefix(".") }.prefix(2)
                guard names.count == 2, let a = names.first, let b = names.last,
                      let placeA = main.layout.place(for: a), let placeB = main.layout.place(for: b) else { s.note("  (need 2 icons)"); return }
                main.layout.setPlace(DesktopLayout.Place(point: CGPoint(x: 0.5, y: 0.5), screenID: id), for: a)
                main.layout.setPlace(DesktopLayout.Place(point: CGPoint(x: 0.5, y: 0.5), screenID: nil), for: b)
                views().forEach { $0.reloadShared() }
                let (ca, cb) = (main.debugCenter(of: a) ?? .zero, main.debugCenter(of: b) ?? .zero)
                s.note("  \(a) at \(Int(ca.x)),\(Int(ca.y)); \(b) at \(Int(cb.x)),\(Int(cb.y))  expect different spots")
                s.note("  stored place of the moved one kept: \(main.layout.place(for: b)?.point == CGPoint(x: 0.5, y: 0.5))  expect true")
                main.layout.setPlace(placeA, for: a)
                main.layout.setPlace(placeB, for: b)
                views().forEach { $0.reloadShared() }
                controller.hide()
            }),
        ])
    }

    /// Real-mouse check, driven by `scripts/mouse-drag-check.swift` (run with the user's consent):
    /// the app places its window and writes where to grab it and where the close button is — only
    /// after checking that at those points the topmost window on screen is this one; the script
    /// drags with the real mouse and clicks close; then a new window opens and its place is logged.
    static func mouseDrag(_ s: Scenario) {
        let app = AppDelegate.shared
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        func cg(_ p: NSPoint) -> String { "\(Int(p.x)) \(Int(mainHeight - p.y))" }
        func isOurs(_ p: NSPoint, _ window: NSWindow) -> Bool {
            NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0) == window.windowNumber
        }
        func write(_ name: String, _ text: String) {
            try? text.write(to: s.output.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: s.output.appendingPathComponent(name).path) }
        func wait(for name: String, then next: @escaping () -> Void, tries: Int = 300) {
            if exists(name) { next(); return }
            guard tries > 0 else { s.note("  (timed out waiting for \(name))"); s.run([]); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait(for: name, then: next, tries: tries - 1) }
        }
        func describe(_ w: NSWindow?) -> String {
            guard let w else { return "-" }
            return "\(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))×\(Int(w.frame.height)) on \(w.screen?.localizedName ?? "?")"
        }
        guard let window = s.window?.window, let second = NSScreen.screens.dropFirst().first else {
            s.note("  (no window or one monitor only)"); s.run([]); return
        }
        window.setFrame(NSRect(x: 500, y: 400, width: 900, height: 600), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let grab = NSPoint(x: window.frame.maxX - 120, y: window.frame.maxY - 26)
            let target = NSPoint(x: second.frame.midX, y: second.frame.midY + 200)
            guard isOurs(grab, window) else { s.note("  another window covers the grab point — aborted"); write("abort", ""); s.run([]); return }
            s.note("  opened: \(describe(window))")
            write("grab.txt", "\(cg(grab)) \(cg(target))")
            wait(for: "dragged") {
                s.note("  after the mouse drag: \(describe(window))  saved on: \(WindowPlacement.saved.flatMap { p in NSScreen.screens.first { $0.displayUUID == p.screenID }?.localizedName } ?? "-")")
                guard let close = window.standardWindowButton(.closeButton) else { s.run([]); return }
                let frame = close.convert(close.bounds, to: nil)
                let point = window.convertPoint(toScreen: NSPoint(x: frame.midX, y: frame.midY))
                guard isOurs(point, window) else { s.note("  close button covered — aborted"); write("abort", ""); s.run([]); return }
                write("close.txt", cg(point))
                wait(for: "closed") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        s.note("  windows after the click on close: \(app.windowControllers.count)")
                        // Like a click on the Dock icon with no windows
                        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            s.note("  reopened: \(describe(s.window?.window))  expect on \(second.localizedName)")
                            s.run([])
                        }
                    }
                }
            }
        }
    }

    /// A window closed on the second monitor: the next one must open there. Logs every save.
    static func placementSecondScreen(_ s: Scenario) {
        let app = AppDelegate.shared
        guard let second = NSScreen.screens.dropFirst().first else { s.note("  (one monitor only)"); s.run([]); return }
        let target = CGRect(x: second.visibleFrame.minX + 200, y: second.visibleFrame.minY + 200, width: 900, height: 600)
        func saved() -> String {
            guard let p = WindowPlacement.saved else { return "-" }
            let screen = NSScreen.screens.first { $0.displayUUID == p.screenID }?.localizedName ?? p.screenID
            return "\(Int(p.frame.minX)),\(Int(p.frame.minY)) \(Int(p.frame.width))×\(Int(p.frame.height)) on \(screen)"
        }
        let main = CGRect(x: 300, y: 300, width: 640, height: 700)
        var onSecond: ExplorerWindowController?
        // Like with "WinEx instead of Finder": the WinEx desktop is on the main monitor
        let desktop = DesktopController()
        if ProcessInfo.processInfo.environment["WINEX_WITH_DESKTOP"] != nil { desktop.show() }
        s.run([
            (0.5, "window A on the main monitor, window B on the second", {
                s.window?.window?.setFrame(main, display: true)
                onSecond = app.openWindow(at: s.sandbox)
                onSecond?.window?.setFrame(target, display: true)
                s.note("  saved: \(saved())")
            }),
            (0.5, "close B (A becomes active by itself)", { onSecond?.window?.performClose(nil) }),
            (0.5, "after close", { s.note("  saved: \(saved())  expect B on \(second.localizedName)  windows: \(app.windowControllers.count)") }),
            (0.2, "open a window while A is open", {
                let w = app.openWindow(at: s.sandbox).window
                s.note("  cascades from A: \(w?.frame ?? .zero) on \(w?.screen?.localizedName ?? "?")")
            }),
            (0.5, "close A and the new one; move a last window to the second monitor and close it", {
                app.windowControllers.forEach { $0.window?.performClose(nil) }
                let last = app.openWindow(at: s.sandbox).window
                last?.setFrame(target, display: true)
                last?.performClose(nil)
            }),
            (0.5, "open after all closed", {
                // A click on the desktop makes it the key window (it's on the main monitor)
                NSApp.windows.first { $0 is DesktopWindow }?.makeKeyAndOrderFront(nil)
                // Opened while another app is active, like a click on the Dock icon
                if ProcessInfo.processInfo.environment["WINEX_INACTIVE"] != nil { NSApp.deactivate() }
                s.note("  key: \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none"), NSScreen.main: \(NSScreen.main?.localizedName ?? "?")")
                let w = app.openWindow(at: s.sandbox).window
                s.note("  new: \(w?.frame ?? .zero) on \(w?.screen?.localizedName ?? "?")  expect \(target) on \(second.localizedName)")
            }),
            (0.5, "a moment later", {
                let w = s.window?.window
                s.note("  new: \(w?.frame ?? .zero) on \(w?.screen?.localizedName ?? "?")")
                desktop.hide()
            }),
        ])
    }

    /// Settings ▸ "Сбросить рабочий стол как в Finder…": Cancel keeps the layout, Reset takes Finder's.
    static func desktopReset(_ s: Scenario) {
        let desktop = DesktopController()
        desktop.show()
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        func stored() -> String {
            guard let data = AppDefaults.store.data(forKey: "desktopLayout"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "-" }
            return "iconSize=\(json["iconSize"] ?? "?") positions=\((json["positions"] as? [String: Any])?.count ?? 0)"
        }
        func settingsWindow() -> NSWindow? { NSApp.windows.first { $0.title == "Настройки WinEx" } }
        func press(_ title: String, in view: NSView?) -> Bool {
            guard let view else { return false }
            if let button = view as? NSButton, button.title == title { button.performClick(nil); return true }
            return view.subviews.contains { press(title, in: $0) }
        }
        func answer(_ title: String) {
            guard let sheet = settingsWindow()?.attachedSheet else { s.note("  (no confirmation shown)"); return }
            s.note("  asked: \(sheet.contentView.flatMap { v in s.find(NSTextField.self, in: v)?.stringValue } ?? "?")")
            if !press(title, in: sheet.contentView) { s.note("  (no \(title) button)") }
        }
        s.run([
            (1.0, "scramble the WinEx layout", {
                s.note("  imported: \(stored())")
                let scrambled: [String: Any] = ["positions": ["x": [0.5, 0.5]], "iconSize": 2, "autoArrange": false,
                                                "alignToGrid": true, "showIcons": true, "sortKey": "name", "importedFromFinder": true]
                AppDefaults.store.set(try? JSONSerialization.data(withJSONObject: scrambled), forKey: "desktopLayout")
                s.note("  scrambled: \(stored())")
                AppDelegate.shared.showSettings(nil)
            }),
            (0.5, "settings layout", {
                guard let stack = settingsWindow()?.contentView as? NSStackView else { s.note("  (no stack)"); return }
                for v in stack.arrangedSubviews {
                    let title = (v as? NSButton)?.title ?? (v as? NSTextField)?.stringValue.prefix(30).description ?? "—"
                    s.note("  \(Int(v.frame.minY))…\(Int(v.frame.maxY)) x\(Int(v.frame.minX)) w\(Int(v.frame.width)) \(title)")
                }
                s.note("  window content: \(Int(stack.bounds.width))×\(Int(stack.bounds.height))")
            }),
            (0.5, "press reset", { if !press("Сбросить рабочий стол как в Finder…", in: settingsWindow()?.contentView) { s.note("  (no button)") } }),
            (0.5, "Cancel", { answer("Отмена") }),
            (0.5, "check", { s.note("  after cancel: \(stored())  expect scrambled") }),
            (0.2, "press reset", { _ = press("Сбросить рабочий стол как в Finder…", in: settingsWindow()?.contentView) }),
            (0.5, "Reset", { answer("Сбросить") }),
            (0.5, "check", {
                let finder = FinderDesktopLayout.iconPlaces(in: desktopURL, screenSizes: NSScreen.screens.map(\.frame.size))
                s.note("  after reset (WinEx desktop off): \(stored())  expect - (imported on next start)")
                AppDefaults.store.set(try? JSONSerialization.data(withJSONObject: ["iconSize": 2, "importedFromFinder": true, "positions": [:]]), forKey: "desktopLayout")
                desktop.resetToFinder()
                s.note("  reset of a running desktop: \(stored())  expect like imported (Finder knows \(finder.count) places, some gone)")
                desktop.hide()
            }),
        ])
    }

    /// Two windows moved around; after both close, a new window opens where the last used one was.
    static func placement(_ s: Scenario) {
        let app = AppDelegate.shared
        let visible = NSScreen.screens.first?.visibleFrame ?? .zero
        let first = CGRect(x: visible.minX + 40, y: visible.minY + 60, width: 800, height: 500)
        let second = CGRect(x: visible.minX + 300, y: visible.minY + 120, width: 900, height: 560)
        var other: ExplorerWindowController?
        func describe(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-" }
        s.run([
            (0.5, "move first window", { s.window?.window?.setFrame(first, display: true) }),
            (0.3, "open a second window, move it", {
                other = app.openWindow(at: s.sandbox)
                other?.window?.setFrame(second, display: true)
            }),
            (0.3, "focus the first again, then the second", {
                s.window?.window?.makeKeyAndOrderFront(nil)
                other?.window?.makeKeyAndOrderFront(nil)
            }),
            (0.3, "close all", { app.windowControllers.forEach { $0.window?.close() } }),
            (0.3, "open a new window", {
                let frame = app.openWindow(at: s.sandbox).window?.frame
                s.note("  new: \(describe(frame))  expect \(describe(second))")
            }),
            (0.3, "a second new window cascades", {
                let frame = app.openWindow(at: s.sandbox).window?.frame
                s.note("  cascaded: \(describe(frame))  expect shifted, 900×560")
            }),
        ])
    }

    /// Shows the WinEx desktop, selects everything (⌘A) and saves a picture of it as desktop.png.
    static func desktop(_ s: Scenario) {
        let controller = DesktopController()
        controller.show()
        var view: DesktopView? { NSApp.windows.lazy.compactMap { $0.contentView as? DesktopView }.first }
        s.run([
            (2.0, "⌘A", {
                guard let view, let window = view.window,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "a",
                                                   charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) else { s.note("  (no desktop)"); return }
                view.keyDown(with: event)
                s.note("  icons: \(view.subviews.count) subviews")
            }),
            (0.5, "Quick Look transition picture", {
                let views = NSApp.windows.compactMap { $0.contentView as? DesktopView }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: DesktopView.desktopURL.path)) ?? []
                for name in names where ["png", "jpg", "jpeg", "webp", "pdf"].contains((name as NSString).pathExtension.lowercased()) {
                    let url = DesktopView.desktopURL.appendingPathComponent(name) as NSURL
                    var rect = NSRect.zero
                    guard let view = views.first(where: { $0.previewPanel(nil, sourceFrameOnScreenFor: url) != .zero }),
                          let image = view.previewPanel(nil, transitionImageFor: url, contentRect: &rect) as? NSImage,
                          let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
                    let corner = rep.colorAt(x: 0, y: 0)?.alphaComponent ?? -1
                    let middle = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? -1
                    s.note("  \(name): corner alpha \(corner), middle alpha \(middle)  expect 0, 1")
                    try? rep.representation(using: .png, properties: [:])?.write(to: s.output.appendingPathComponent("transition.png"))
                    break
                }
            }),
            (1.0, "snapshot of every monitor", {
                let views = NSApp.windows.compactMap { $0.contentView as? DesktopView }
                for view in views {
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = view.window?.screen?.localizedName ?? "?"
                    s.note("  \(name): \(view.subviews.count) icons")
                    try? rep.representation(using: .png, properties: [:])?.write(to: s.output.appendingPathComponent("desktop-\(name).png"))
                }
                controller.hide()
            }),
        ])
    }

    /// Does the window server count a nearly transparent window as "there" (so it gets clicks)?
    /// Asks it for the window under a point — no real mouse involved.
    static func hitTest(_ s: Scenario) {
        final class LayerFill: NSView {
            var alpha: CGFloat = 0
            override var wantsUpdateLayer: Bool { true }
            override func updateLayer() { layer?.backgroundColor = NSColor(white: 0, alpha: alpha).cgColor }
        }
        final class DrawFill: NSView {
            override func draw(_ dirtyRect: NSRect) { NSColor(white: 0, alpha: 0.005).setFill(); dirtyRect.fill(using: .copy) }
        }
        let clear = LayerFill(), layer = LayerFill()
        layer.alpha = 0.005
        let cases: [(String, NSView)] = [("clear layer (control)", clear), ("layer 0.005", layer), ("draw 0.005", DrawFill())]
        let screen = NSScreen.screens.first?.frame ?? .zero
        let windows = cases.enumerated().map { n, c -> NSWindow in
            let w = NSWindow(contentRect: NSRect(x: screen.minX + 20 + CGFloat(n) * 120, y: screen.minY + 200, width: 100, height: 100),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentView = c.1
            w.orderFront(nil)
            return w
        }
        s.run([
            (1.0, "query", {
                for (w, c) in zip(windows, cases) {
                    let hit = NSWindow.windowNumber(at: NSPoint(x: w.frame.midX, y: w.frame.midY), belowWindowWithWindowNumber: 0)
                    s.note("  \(c.0): \(hit == w.windowNumber ? "catches clicks" : "clicks pass through")")
                }
                windows.forEach { $0.orderOut(nil) }
            }),
        ])
    }

    /// ⌘Z / ⇧⌘Z for rename, trash, move, new folder, tags; ⌘Z in a text field undoes typing.
    static func undo(_ s: Scenario) {
        let base = s.makeFiles(["a.txt", "b.txt", "dir/"])
        s.window?.navigate(to: base)
        s.setViewMode(.details)
        // File work of undo / redo runs in the background: wait for it before looking at the files
        func undo() { s.key("z", code: 6, modifiers: .command, viaMenu: true); FileUndo.waitForFileWork() }
        func redo() { s.key("Z", code: 6, modifiers: [.command, .shift], viaMenu: true); FileUndo.waitForFileWork() }
        s.run([
            (0.8, "start", { s.note("  \(s.files())") }),
            (0.1, "rename a.txt → renamed.txt", {
                s.select("a.txt"); s.send("renameSelected:")
                if let editor = s.window?.window?.firstResponder as? NSTextView {
                    editor.selectAll(nil); editor.insertText("renamed.txt", replacementRange: editor.selectedRange()); editor.insertNewline(nil)
                }
            }),
            (0.5, "⌘Z", { undo(); s.note("  \(s.files())  expect a.txt") }),
            (0.5, "⇧⌘Z", { redo(); s.note("  \(s.files())  expect renamed.txt") }),
            (0.5, "⌘Z", { undo() }),
            (0.5, "trash b.txt", { s.select("b.txt"); s.send("moveToTrash:") }),
            (1.2, "⌘Z", { undo(); s.note("  \(s.files())  expect b.txt back") }),
            (0.5, "cut a.txt, paste into dir", { s.select("a.txt"); s.send("cut:"); FileClipboard.shared.paste(into: base.appendingPathComponent("dir")) }),
            (1.0, "⌘Z", { undo(); s.note("  \(s.files()) dir=\(s.files(in: base.appendingPathComponent("dir")))  expect a.txt back") }),
            (0.5, "tag b.txt", { FileTags.toggle(FileTags.Tag(name: "Красный", color: 6), on: [base.appendingPathComponent("b.txt")], add: true) }),
            (0.3, "⌘Z", { undo(); s.note("  tags: \(FileTags.tags(of: base.appendingPathComponent("b.txt")).map(\.name))  expect []") }),
            (0.3, "type in the address bar, ⌘Z", {
                s.send("focusPathField:")
                guard let editor = s.window?.window?.firstResponder as? NSTextView else { s.note("  (no editor)"); return }
                editor.moveToEndOfDocument(nil)
                for (ch, code) in [("x", UInt16(7)), ("y", 16)] { s.key(ch, code: code) }
                undo()
                s.note("  address: …\(editor.string.suffix(6))  expect no «xy»")
            }),
        ])
    }

    /// ⇧⌘N → type a name → Return: the new folder stays selected (table and icons).
    static func newFolder(_ s: Scenario) {
        let base = s.makeFiles(["file.txt"])
        s.window?.navigate(to: base)
        func typeName(_ name: String) {
            guard let editor = s.window?.window?.firstResponder as? NSTextView else { s.note("  (not editing)"); return }
            editor.selectAll(nil)
            editor.insertText(name, replacementRange: editor.selectedRange())
            s.key("\r", code: 36)
        }
        s.run([
            (0.3, "table", { s.setViewMode(.details) }),
            (0.5, "⇧⌘N", { s.key("N", code: 45, modifiers: [.command, .shift], viaMenu: true); s.note("  editing: \(s.editingText)") }),
            (0.5, "type «Проекты» + Return", { typeName("Проекты") }),
            (0.8, "check", { s.note("  selected: \(s.selectedNames)  expect [Проекты]") }),
            (0.2, "icons", { s.setViewMode(.mediumIcons) }),
            (0.5, "⇧⌘N", { s.key("N", code: 45, modifiers: [.command, .shift], viaMenu: true) }),
            (0.5, "type «Архив» + Return", { typeName("Архив") }),
            (0.8, "check", { s.note("  selected: \(s.selectedNames)  expect [Архив]") }),
        ])
    }

    /// Clicking the name of the already selected item renames it after a pause; other clicks don't.
    static func slowClick(_ s: Scenario) {
        let base = s.makeFiles(["alpha.txt", "beta.txt", "folder/"])
        s.window?.navigate(to: base)
        func point(_ name: String, label: Bool) -> (NSView, NSPoint)? {
            guard let grid = s.grid else { return nil }
            for i in 0..<grid.count {
                guard let item = grid.item(at: IndexPath(item: i, section: 0)) as? FileGridItem,
                      item.textField?.stringValue.hasSuffix(name) == true,
                      let frame = grid.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame else { continue }
                // The name's area (from the item's label frame) or the icon's middle
                if label, let field = item.textField {
                    let rect = field.convert(field.bounds, to: grid)
                    return (grid, NSPoint(x: rect.midX, y: rect.midY - 4))
                }
                return (grid, NSPoint(x: frame.midX, y: frame.minY + 40))
            }
            s.note("  (\(name) not found)")
            return nil
        }
        func click(_ name: String, label: Bool, clicks: Int = 1) {
            if let (view, p) = point(name, label: label) { s.click(view, at: p, clicks: clicks) }
        }
        s.run([
            (0.3, "icons", { s.setViewMode(.mediumIcons) }),
            (0.8, "click alpha icon", { click("alpha.txt", label: false) }),
            (1.0, "click alpha label", { click("alpha.txt", label: true); s.note("  right away: \(s.editingText)  expect -") }),
            (0.8, "later", { s.note("  editing: \(s.editingText)  expect alpha.txt"); s.window?.window?.makeFirstResponder(s.grid) }),
            (0.4, "click beta label (not selected)", { click("beta.txt", label: true) }),
            (1.0, "later", { s.note("  editing: \(s.editingText)  expect -") }),
            (0.1, "select folder, double-click its label", {
                click("folder", label: false)
                click("folder", label: true); click("folder", label: true, clicks: 2)
            }),
            (1.0, "later", { s.note("  location: \(s.window?.selectedTab.title ?? "?") editing: \(s.editingText)  expect folder, -") }),
        ])
    }

    /// Opening / reloading a 10 000-file folder: how long, and how long the UI stalls.
    static func perf(_ s: Scenario) {
        let big = s.sandbox.appendingPathComponent("big")
        try? FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 1...10_000 { FileManager.default.createFile(atPath: big.appendingPathComponent("file-\(i).txt").path, contents: nil) }
        s.note(String(format: "after launch: %.0f MB", s.footprintMB))

        // Watchdog on a background thread: every 5 ms it asks the main thread to answer; the longest
        // wait is the longest UI stall (a timer on the main thread can't see its own blockage)
        let watchdog = StallWatchdog()
        watchdog.start()
        var worst: TimeInterval { watchdog.worst }
        func loaded() -> Int { s.table?.numberOfRows ?? 0 }
        func measure(_ title: String, count: Int = 10_000, _ action: @escaping () -> Void, then next: @escaping () -> Void) {
            watchdog.reset()
            let start = Date()
            action()
            func poll() {
                if loaded() == count || Date().timeIntervalSince(start) > 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        s.note(String(format: "%@: %.0f ms until listed, longest UI stall %.0f ms", title, Date().timeIntervalSince(start) * 1000 - 50, worst * 1000))
                        next()
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
                }
            }
            poll()
        }
        s.setViewMode(.details)
        measure("open 10 000 files", { s.window?.navigate(to: big) }) {
            // A burst of 200 new files, like a copy in progress: wait until they're all listed
            measure("200 files added in a burst", count: 10_200, {
                for i in 1...200 { FileManager.default.createFile(atPath: big.appendingPathComponent("new-\(i).txt").path, contents: nil) }
            }) {
                s.note(String(format: "in the big folder: %.0f MB", s.footprintMB))
                let desktop = DesktopController()
                desktop.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    s.note(String(format: "with the desktop (+5 s): %.0f MB", s.footprintMB))
                    desktop.hide()
                    watchdog.stop()
                    s.run([])
                }
            }
        }
    }
}
/// Measures how long the main thread takes to answer, from a background thread.
final class StallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var longest: TimeInterval = 0
    private var running = false

    var worst: TimeInterval { lock.withLock { longest } }
    func reset() { lock.withLock { longest = 0 } }

    func start() {
        running = true
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let delay = Date().timeIntervalSince(sent)
                lock.withLock { longest = max(longest, delay) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func stop() { lock.withLock { running = false } }
}
#endif
