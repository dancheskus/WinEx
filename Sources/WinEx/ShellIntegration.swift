import Foundation

/// Settings ▸ Finder: `open <folder>` in the Terminal opens the folder in WinEx.
///
/// macOS doesn't let an app become the handler of folders (LaunchServices refuses `public.folder`),
/// so plain `open` always asks Finder. Instead a small `open` function goes into the shell's
/// startup file (zsh, and bash if it's set up): folders go to WinEx, everything else — files,
/// apps, packages, URLs, options — to the real `open`. Removed again when switched off.
enum ShellIntegration {
    private static let begin = "# >>> WinEx: open folders in WinEx >>>"
    private static let end = "# <<< WinEx <<<"

    /// The startup files it goes into: ~/.zshrc (created if needed; zsh is macOS's shell), and
    /// ~/.bash_profile when it already exists.
    private static var files: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["WINEX_SHELL_HOME"] {
            let fake = URL(fileURLWithPath: dir)
            return [fake.appendingPathComponent(".zshrc"), fake.appendingPathComponent(".bash_profile")]
        }
        #endif
        let bash = home.appendingPathComponent(".bash_profile")
        return [home.appendingPathComponent(".zshrc")] + (FileManager.default.fileExists(atPath: bash.path) ? [bash] : [])
    }

    static var snippet: String {
        let id = Bundle.main.bundleIdentifier ?? "dev.winex.WinEx"
        return """
        \(begin)
        # Added by WinEx (Settings ▸ Finder). Folders go to WinEx; files, apps, packages, URLs and
        # options go to the real `open`. Switch it off there to remove these lines.
        open() {
          local arg
          [ $# -eq 0 ] && { command open "$@"; return; }
          for arg in "$@"; do
            case "$arg" in -*) command open "$@"; return ;; esac
            [ -d "$arg" ] || { command open "$@"; return; }
            /usr/bin/mdls -raw -name kMDItemContentTypeTree -- "$arg" 2>/dev/null | /usr/bin/grep -q '"com.apple.package"' && { command open "$@"; return; }
          done
          command open -b \(id) "$@"
        }
        \(end)
        """
    }

    static var isInstalled: Bool {
        files.contains { (try? String(contentsOf: $0, encoding: .utf8))?.contains(begin) == true }
    }

    static func install() throws {
        for file in files {
            var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            text = removed(from: text)
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += (text.isEmpty ? "" : "\n") + snippet + "\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static func uninstall() throws {
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(begin) else { continue }
            try removed(from: text).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// `text` without WinEx's block (and the blank line before it).
    static func removed(from text: String) -> String {
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { return text }
        var lower = start.lowerBound
        if lower > text.startIndex, text[text.index(before: lower)] == "\n" {
            let before = text.index(before: lower)
            if before > text.startIndex, text[text.index(before: before)] == "\n" { lower = before }
        }
        var upper = stop.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        return String(text[..<lower]) + String(text[upper...])
    }
}
