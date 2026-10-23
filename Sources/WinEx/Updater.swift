import AppKit
import Security

/// Updates WinEx from GitHub Releases (built and published by .github/workflows/release.yml).
///
/// - Checks once a day (and via "Проверить обновления…"); local "dev" builds only on request.
/// - The new version is downloaded by WinEx itself, so macOS doesn't quarantine it: no Gatekeeper
///   prompt. It's installed only if it's signed with the same certificate as the running app —
///   which also keeps every privacy permission (they're tied to that certificate).
/// - The app bundle is swapped after WinEx quits, then the new version starts; the desktop and
///   "instead of Finder" mode stay on, Finder isn't brought back in between.
@MainActor
final class Updater {
    static let shared = Updater()
    static let repository = "dancheskus/WinEx"

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL?
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var archive: Asset? { assets.first { $0.name.hasPrefix("WinEx") && $0.name.hasSuffix(".zip") } }
    }

    /// Set while quitting to install an update: Finder must not be brought back meanwhile.
    private(set) var isRelaunching = false
    private var timer: Timer?
    private var checking = false

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// Local builds (build.sh without VERSION) — never updated behind the developer's back.
    var isDevBuild: Bool { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "dev" }

    static var automaticChecks: Bool {
        get { AppDefaults.store.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { AppDefaults.store.set(newValue, forKey: "checkForUpdates") }
    }

    private var feedURL: URL {
        #if DEBUG
        if let feed = ProcessInfo.processInfo.environment["WINEX_UPDATE_FEED"] { return URL(fileURLWithPath: feed) }
        #endif
        return URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
    }

    /// A check a minute after launch, then every day (with a generous tolerance: the system may
    /// bundle the wake-up with others).
    func startAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        guard Self.automaticChecks, !isDevBuild else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check(userInitiated: false) }
        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Checking

    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        var request = URLRequest(url: feedURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WinEx/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        Task {
            defer { checking = false }
            do {
                let data: Data
                if feedURL.isFileURL { data = try Data(contentsOf: feedURL) } else { data = try await URLSession.shared.data(for: request).0 }
                let release = try JSONDecoder().decode(Release.self, from: data)
                handle(release, userInitiated: userInitiated)
            } catch {
                if userInitiated { tell(L("Не удалось проверить обновления"), error.localizedDescription) }
            }
        }
    }

    private func handle(_ release: Release, userInitiated: Bool) {
        // A build from source may be newer than any release: never replace it with one
        if isDevBuild {
            guard userInitiated else { return }
            let alert = NSAlert()
            alert.messageText = L("Это своя сборка WinEx")
            alert.informativeText = L("Она собрана из исходников и не заменяется релизами (последний — %@). Чтобы получать обновления автоматически, установите WinEx со страницы релизов.", release.version)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: L("Страница релизов…"))
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn, let url = release.html_url ?? URL(string: "https://github.com/\(Self.repository)/releases") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard Self.isVersion(release.version, newerThan: currentVersion), release.archive != nil else {
            if userInitiated { tell(L("Установлена последняя версия"), L("WinEx %@ — самая новая.", currentVersion)) }
            return
        }
        if !userInitiated && AppDefaults.store.string(forKey: "skippedVersion") == release.version { return }
        #if DEBUG
        // Scenario "selfupdate": install without asking
        if ProcessInfo.processInfo.environment["WINEX_AUTO_UPDATE"] != nil { return install(release) }
        #endif
        let alert = NSAlert()
        alert.messageText = L("Доступна новая версия WinEx %@", release.version)
        alert.informativeText = L("У вас %@.", currentVersion)
        // What's new: the release notes styled (sections, bullets), in a short scrolling box
        let notes = ReleaseNotes.styled(release.body ?? "")
        if notes.length > 0 { alert.accessoryView = ReleaseNotes.view(notes) }
        alert.addButton(withTitle: L("Обновить и перезапустить"))
        alert.addButton(withTitle: L("Позже"))
        alert.addButton(withTitle: L("Пропустить эту версию"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: AppDefaults.store.set(release.version, forKey: "skippedVersion")
        default: break
        }
    }

    /// "1.10.0" is newer than "1.9.2"; a missing part counts as 0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Installing

    private func install(_ release: Release) {
        guard let asset = release.archive else { return }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            tell(L("Не удалось обновить WinEx"), L("Нет прав на запись в «%@». Переместите WinEx в «Программы».", target.deletingLastPathComponent().path))
            return
        }
        let indicator = BusyIndicator(title: L("Загрузка WinEx %@…", release.version)) {}
        Task {
            do {
                let app = try await download(asset.browser_download_url)
                indicator.close()
                guard Self.isSignedLikeUs(app) else {
                    tell(L("Обновление не установлено"), L("Новая версия подписана другим сертификатом — это может быть подделка. Скачайте WinEx вручную со страницы релизов."))
                    return
                }
                relaunch(replacing: target, with: app, release: release)
            } catch {
                indicator.close()
                tell(L("Не удалось загрузить обновление"), error.localizedDescription)
            }
        }
    }

    /// Downloads and unpacks the release archive; returns the new WinEx.app (in a temporary folder).
    func download(_ url: URL) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winex-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("update.zip")
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: archive)
        } else {
            let (downloaded, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: downloaded, to: archive)
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, folder.path]
        try unzip.run()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                unzip.waitUntilExit()
                continuation.resume()
            }
        }
        guard unzip.terminationStatus == 0,
              let app = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw CocoaError(.fileReadCorruptFile) }
        return app
    }

    /// The new app satisfies the running app's designated requirement: same identifier, same
    /// certificate. (An ad-hoc build's requirement is its own hash — nothing else passes it.)
    nonisolated static func isSignedLikeUs(_ app: URL) -> Bool {
        var me: SecCode?
        var myStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic,
              SecCodeCopyDesignatedRequirement(myStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess
    }

    /// Quits, swaps the bundle once this process is gone, starts the new version — with the same
    /// windows, and a word on what it brings.
    private func relaunch(replacing target: URL, with app: URL, release: Release) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let old = target.path, backup = target.path + ".old", new = app.path
        let marker = FinderReplacement.updateMarker(for: pid)
        FileManager.default.createFile(atPath: marker, contents: nil)
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(backup)"
            if mv "\(old)" "\(backup)" && mv "\(new)" "\(old)"; then rm -rf "\(backup)"; else mv "\(backup)" "\(old)"; fi
            /usr/bin/open "\(old)"\(Self.relaunchArguments)
            sleep 5; rm -f "\(marker)"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            tell(L("Не удалось обновить WinEx"), error.localizedDescription)
            return
        }
        AppDelegate.shared.saveSession(settingsOpen: AppDelegate.shared.settingsOpen, settingsTab: .updates)
        AppDefaults.store.set(["from": currentVersion, "to": release.version, "notes": release.body ?? "",
                               "page": release.html_url?.absoluteString ?? ""], forKey: Self.updateNoticeKey)
        isRelaunching = true
        NSApp.terminate(nil)
    }

    // MARK: After an update

    /// Written before quitting for an update; the new version reads it once at launch.
    private static let updateNoticeKey = "justUpdated"

    #if DEBUG
    /// Scenario runs: what the window would have said (no dialog).
    private(set) var debugUpdateNotice: String?
    #endif

    /// The version that ran last time (releases only): a newer one now means it was updated, even
    /// by a version that didn't leave word (before 0.9.22) or by hand.
    private static let lastRunKey = "lastRunVersion"

    /// Started by an update: says it's done — the version, what it was, what's new (the release
    /// notes, as in the offer), a link to the release page. If the swap failed and the old version
    /// came back, says that instead. True when it was updated without word from the version before
    /// (its windows weren't saved for this: the caller opens the ones it had).
    @discardableResult
    func tellWhatsNewIfUpdated() -> Bool {
        let store = AppDefaults.store
        var isRelease = !isDevBuild
        #if DEBUG
        if Scenario.isRequested { isRelease = true }
        #endif
        let last = store.string(forKey: Self.lastRunKey)
        if isRelease { store.set(currentVersion, forKey: Self.lastRunKey) }
        if let notice = store.dictionary(forKey: Self.updateNoticeKey) {
            store.removeObject(forKey: Self.updateNoticeKey)
            let to = notice["to"] as? String ?? currentVersion
            tellUpdated(from: notice["from"] as? String ?? "", notes: notice["notes"] as? String ?? "",
                        page: (notice["page"] as? String).flatMap(URL.init(string:)),
                        failedVersion: Self.isVersion(to, newerThan: currentVersion) ? to : nil)
            return false
        }
        guard isRelease, let last, Self.isVersion(currentVersion, newerThan: last) else { return false }
        // No word left: this version's notes from its release page
        Task {
            let release = await releaseNotes(of: currentVersion)
            tellUpdated(from: last, notes: release?.body ?? "", page: release?.html_url, failedVersion: nil)
        }
        return true
    }

    /// The release of `version` from GitHub (nil when it can't be had: offline, no such release).
    private func releaseNotes(of version: String) async -> Release? {
        #if DEBUG
        if let feed = ProcessInfo.processInfo.environment["WINEX_UPDATE_FEED"] {
            return (try? Data(contentsOf: URL(fileURLWithPath: feed))).flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
        }
        if Scenario.isRequested { return nil }
        #endif
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/tags/v\(version)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("WinEx/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Release.self, from: data)
    }

    private func tellUpdated(from: String, notes markdown: String, page: URL?, failedVersion: String?) {
        let page = page.flatMap { $0.scheme == nil ? nil : $0 } ?? URL(string: "https://github.com/\(Self.repository)/releases")
        let alert = NSAlert()
        if let failedVersion {
            alert.messageText = L("Не удалось обновить WinEx")
            alert.informativeText = L("Версия %@ не установилась, работает %@. Её можно скачать со страницы релизов.", failedVersion, currentVersion)
        } else {
            alert.messageText = L("WinEx обновлён до версии %@", currentVersion)
            let notes = ReleaseNotes.styled(markdown)
            if notes.length > 0 {
                alert.informativeText = L("Была версия %@. Что нового:", from)
                alert.accessoryView = ReleaseNotes.view(notes)
            } else {
                alert.informativeText = L("Была версия %@.", from)
            }
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: failedVersion == nil ? L("Все изменения…") : L("Страница релизов…"))
        #if DEBUG
        if Scenario.isRequested { debugUpdateNotice = alert.messageText + " | " + alert.informativeText; return }
        #endif
        // (Once the windows have come back: the note goes over them)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn, let page { NSWorkspace.shared.open(page) }
        }
    }

    /// Quits and starts again (a new language takes effect); Finder isn't brought back meanwhile.
    func restart() {
        #if DEBUG
        if Scenario.isRequested { return }  // never relaunch the user's WinEx from a test run
        #endif
        let pid = ProcessInfo.processInfo.processIdentifier
        let marker = FinderReplacement.updateMarker(for: pid)
        FileManager.default.createFile(atPath: marker, contents: nil)
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            /usr/bin/open "\(Bundle.main.bundleURL.path)"
            sleep 5; rm -f "\(marker)"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        isRelaunching = true
        NSApp.terminate(nil)
    }

    /// Scenario runs relaunch into a scenario too (never into the user's settings).
    private static var relaunchArguments: String {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let out = env["WINEX_SCENARIO_OUT"], env["WINEX_SCENARIO"] != nil {
            return " --env WINEX_SCENARIO=updated --env WINEX_SCENARIO_OUT=\"\(out)\""
        }
        #endif
        return ""
    }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}

/// GitHub release notes (Markdown) for the update window: "### Section" as a bold heading,
/// "- item" as a bullet with a hanging indent, **bold** as bold; the "## What's new" title and the
/// "Full Changelog" link are left out.
enum ReleaseNotes {
    static func styled(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12)
        let bullet = NSMutableParagraphStyle()
        bullet.headIndent = 12
        bullet.firstLineHeadIndent = 0
        bullet.paragraphSpacing = 3
        bullet.tabStops = [NSTextTab(textAlignment: .left, location: 12)]
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacingBefore = 6
        heading.paragraphSpacing = 3
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("## ") || line.hasPrefix("# ") || line.contains("Full Changelog") { continue }
            if !result.string.isEmpty { result.append(NSAttributedString(string: "\n")) }
            if line.hasPrefix("### ") {
                result.append(NSAttributedString(string: String(line.dropFirst(4)), attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: heading,
                ]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(inline("•\t" + line.dropFirst(2), font: body, style: bullet))
            } else {
                result.append(inline(line, font: body, style: bullet))
            }
        }
        return result
    }

    /// One line with its **bold** parts bold (backticks dropped).
    private static func inline(_ text: String, font: NSFont, style: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        for (index, part) in text.replacingOccurrences(of: "`", with: "").components(separatedBy: "**").enumerated() {
            result.append(NSAttributedString(string: part, attributes: [
                .font: index % 2 == 1 ? bold : font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
        }
        return result
    }

    /// The notes in a box under the alert's text: as tall as they are, up to a scrolling 220 points.
    @MainActor
    static func view(_ notes: NSAttributedString) -> NSView {
        let width: CGFloat = 400
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.isEditable = false
        // Not selectable: the alert made a selectable text its first responder, which scrolled the
        // notes away from their start (the async scroll to the top below didn't win against it)
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.textContainer?.widthTracksTextView = true
        // Narrowed by the scroller, the text grows taller to fit instead of being cut off
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(notes)
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        let height = (textView.textContainer.flatMap { textView.layoutManager?.usedRect(for: $0).height } ?? 200) + 12
        let scroll = TopScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(height, 220)))
        scroll.documentView = textView
        scroll.hasVerticalScroller = height > 220
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // (Automatic insets left the first lines a few points scrolled in)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        textView.frame.size.height = height
        return scroll
    }

    /// Starts at the first section: the alert lays its views out after they're made, which left
    /// the box scrolled to the middle.
    private final class TopScrollView: NSScrollView {
        /// Until the user scrolls, every layout (the alert's, the text reflowing beside the
        /// scroller) keeps the start in view — one scroll to the top when shown came too early.
        private var userScrolled = false

        override func layout() {
            super.layout()
            guard !userScrolled, contentView.bounds.origin != .zero else { return }
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
        }

        override func scrollWheel(with event: NSEvent) {
            userScrolled = true
            super.scrollWheel(with: event)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [self] in needsLayout = true }
        }
    }
}

