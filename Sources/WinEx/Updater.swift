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
                if userInitiated { tell("Не удалось проверить обновления", error.localizedDescription) }
            }
        }
    }

    private func handle(_ release: Release, userInitiated: Bool) {
        // A build from source may be newer than any release: never replace it with one
        if isDevBuild {
            guard userInitiated else { return }
            let alert = NSAlert()
            alert.messageText = "Это своя сборка WinEx"
            alert.informativeText = "Она собрана из исходников и не заменяется релизами (последний — \(release.version)). Чтобы получать обновления автоматически, установите WinEx со страницы релизов."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Страница релизов…")
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn, let url = release.html_url ?? URL(string: "https://github.com/\(Self.repository)/releases") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard Self.isVersion(release.version, newerThan: currentVersion), release.archive != nil else {
            if userInitiated { tell("Установлена последняя версия", "WinEx \(currentVersion) — самая новая.") }
            return
        }
        if !userInitiated && AppDefaults.store.string(forKey: "skippedVersion") == release.version { return }
        #if DEBUG
        // Scenario "selfupdate": install without asking
        if ProcessInfo.processInfo.environment["WINEX_AUTO_UPDATE"] != nil { return install(release) }
        #endif
        let alert = NSAlert()
        alert.messageText = "Доступна новая версия WinEx \(release.version)"
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 900 { notes = String(notes.prefix(900)) + "…" }
        alert.informativeText = "У вас \(currentVersion)." + (notes.isEmpty ? "" : "\n\n" + notes)
        alert.addButton(withTitle: "Обновить и перезапустить")
        alert.addButton(withTitle: "Позже")
        alert.addButton(withTitle: "Пропустить эту версию")
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
            tell("Не удалось обновить WinEx", "Нет прав на запись в «\(target.deletingLastPathComponent().path)». Переместите WinEx в «Программы».")
            return
        }
        let indicator = BusyIndicator(title: "Загрузка WinEx \(release.version)…") {}
        Task {
            do {
                let app = try await download(asset.browser_download_url)
                indicator.close()
                guard Self.isSignedLikeUs(app) else {
                    tell("Обновление не установлено", "Новая версия подписана другим сертификатом — это может быть подделка. Скачайте WinEx вручную со страницы релизов.")
                    return
                }
                relaunch(replacing: target, with: app)
            } catch {
                indicator.close()
                tell("Не удалось загрузить обновление", error.localizedDescription)
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

    /// Quits, swaps the bundle once this process is gone, starts the new version.
    private func relaunch(replacing target: URL, with app: URL) {
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
            tell("Не удалось обновить WinEx", error.localizedDescription)
            return
        }
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
