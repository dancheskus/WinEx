import Foundation

/// Renaming several items at once («Переименовать N объектов»): a few fixed steps, applied top to
/// bottom to the name without its extension (the extension is never touched), each doing nothing
/// while it's empty. No patterns: what's typed is what's found and added.
struct BatchRenameRules: Codable, Equatable {
    /// A set of rules kept under a name («Шаблоны»).
    struct Preset: Codable, Equatable {
        var name: String
        var rules: BatchRenameRules
    }

    enum Numbering: String, Codable, CaseIterable { case off, start, end }
    /// Between the number and the name: "Отпуск 01", "Отпуск_01", "Отпуск-01", "Отпуск (1)".
    enum Separator: String, Codable, CaseIterable { case space, underscore, dash, parentheses }
    enum Case: String, Codable, CaseIterable { case keep, lower, upper, words, sentence }

    /// «Убрать номера, которые уже есть»: digits at the start and the end of the name go, with
    /// what separates them ("Тест 10", "01-Тест", "Тест (2)" → "Тест") — to number them anew.
    var removeNumbers = false
    /// «Заменить»: plain text, every occurrence; an empty `replaceWith` removes it.
    var find = ""
    var replaceWith = ""
    var matchCase = false
    /// «Новое имя»: the whole name (without its extension) becomes this; «Заменить» is off then.
    var newName = ""
    var prefix = ""
    var suffix = ""
    var numbering = Numbering.off
    var startNumber = 1
    /// Digits of the number with leading zeros; 0: as many as the last number has (01…12).
    var digits = 0
    var separator = Separator.space
    var textCase = Case.keep

    init() {}

    /// Saved rules from a version with fewer steps: the missing ones are off.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let empty = BatchRenameRules()
        removeNumbers = try c.decodeIfPresent(Bool.self, forKey: .removeNumbers) ?? empty.removeNumbers
        find = try c.decodeIfPresent(String.self, forKey: .find) ?? empty.find
        replaceWith = try c.decodeIfPresent(String.self, forKey: .replaceWith) ?? empty.replaceWith
        matchCase = try c.decodeIfPresent(Bool.self, forKey: .matchCase) ?? empty.matchCase
        newName = try c.decodeIfPresent(String.self, forKey: .newName) ?? empty.newName
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? empty.prefix
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? empty.suffix
        numbering = try c.decodeIfPresent(Numbering.self, forKey: .numbering) ?? empty.numbering
        startNumber = try c.decodeIfPresent(Int.self, forKey: .startNumber) ?? empty.startNumber
        digits = try c.decodeIfPresent(Int.self, forKey: .digits) ?? empty.digits
        separator = try c.decodeIfPresent(Separator.self, forKey: .separator) ?? empty.separator
        textCase = try c.decodeIfPresent(Case.self, forKey: .textCase) ?? empty.textCase
    }
}

enum BatchRename {
    struct Item: Equatable {
        let url: URL
        let isFolder: Bool
    }

    enum Problem: Equatable {
        case empty, invalidCharacters, hidden, tooLong, duplicate, exists
    }

    struct Outcome: Equatable {
        let item: Item
        let newName: String
        let problem: Problem?
        var oldName: String { item.url.lastPathComponent }
        var changes: Bool { newName != oldName }
        var destination: URL { item.url.deletingLastPathComponent().appendingPathComponent(newName) }
    }

    /// The new name of every item, in order (the order numbers them), with what's wrong with it.
    /// `existing`: the names in each item's folder (by the folder's path), lowercased — a new name
    /// taken by something not being renamed is a conflict.
    static func preview(_ items: [Item], rules: BatchRenameRules, existing: [String: Set<String>]) -> [Outcome] {
        let last = rules.startNumber + max(items.count - 1, 0)
        let digits = rules.digits > 0 ? rules.digits : String(max(last, 0)).count
        let names = items.enumerated().map { index, item in
            newName(for: item, number: rules.startNumber + index, digits: digits, rules: rules)
        }
        // Names that end up the same in one folder (case doesn't count: macOS volumes ignore it)
        var counts: [String: Int] = [:]
        for (item, name) in zip(items, names) { counts[key(item, name), default: 0] += 1 }
        let renamed = Set(items.map { key($0, $0.url.lastPathComponent) })
        return zip(items, names).map { item, name in
            let problem: Problem?
            if name == item.url.lastPathComponent {
                problem = nil
            } else if baseName(of: name, for: item).trimmingCharacters(in: .whitespaces).isEmpty {
                problem = .empty
            } else if name.contains("/") || name.contains(":") {
                problem = .invalidCharacters
            } else if name.hasPrefix(".") {
                problem = .hidden
            } else if name.utf8.count > 255 {
                problem = .tooLong
            } else if counts[key(item, name), default: 0] > 1 {
                problem = .duplicate
            } else if existing[folder(item), default: []].contains(name.lowercased()),
                      !renamed.contains(key(item, name)) {
                problem = .exists
            } else {
                problem = nil
            }
            return Outcome(item: item, newName: name, problem: problem)
        }
    }

    /// One item's new name (with its extension, unchanged).
    static func newName(for item: Item, number: Int, digits: Int, rules: BatchRenameRules) -> String {
        let ext = self.ext(of: item)
        var base = baseName(of: item.url.lastPathComponent, for: item)

        if rules.removeNumbers {
            base = base.replacingOccurrences(of: #"^\(?\d+\)?[ _.\-]*"#, with: "", options: .regularExpression)
            base = base.replacingOccurrences(of: #"[ _.\-]*\(?\d+\)?$"#, with: "", options: .regularExpression)
        }
        if !rules.newName.isEmpty {
            base = rules.newName
        } else if !rules.find.isEmpty {
            base = base.replacingOccurrences(of: rules.find, with: rules.replaceWith,
                                             options: rules.matchCase ? [] : [.caseInsensitive])
        }
        // The case is the whole name's, added text too (the number has none)
        base = rules.prefix + base + rules.suffix
        switch rules.textCase {
        case .keep: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .words: base = base.capitalized
        case .sentence: base = base.prefix(1).uppercased() + base.dropFirst().lowercased()
        }
        if rules.numbering != .off {
            let padded = String(repeating: "0", count: max(digits - String(number).count, 0)) + String(number)
            let separator = switch rules.separator {
            case .space, .parentheses: " "
            case .underscore: "_"
            case .dash: "-"
            }
            let number = rules.separator == .parentheses ? "(\(padded))" : padded
            base = rules.numbering == .start ? number + separator + base : base + separator + number
        }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// The extension kept (folders have none: "v1.2" is a name).
    private static func ext(of item: Item) -> String {
        item.isFolder ? "" : (item.url.lastPathComponent as NSString).pathExtension
    }

    /// `name` without the item's extension.
    private static func baseName(of name: String, for item: Item) -> String {
        let ext = ext(of: item)
        return ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    }

    private static func folder(_ item: Item) -> String { item.url.deletingLastPathComponent().standardizedFileURL.path }
    private static func key(_ item: Item, _ name: String) -> String { folder(item) + "/" + name.lowercased() }

    /// The names in the items' folders, for `preview` (read once, not on every key typed).
    static func existingNames(for items: [Item]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for path in Set(items.map(folder)) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            result[path] = Set(names.map { $0.lowercased() })
        }
        return result
    }

    /// Renames, in two passes — every item to a temporary name, then to its new one — so names can
    /// be swapped (a→b, b→a), passed along (a→b, b→c) or change only their case. The first error
    /// puts everything back as it was and is thrown.
    static func perform(_ pairs: [(from: URL, to: URL)]) throws {
        let fm = FileManager.default
        let pairs = pairs.filter { $0.from.path != $0.to.path }
        let temporary = pairs.map {
            $0.from.deletingLastPathComponent().appendingPathComponent(".winex-rename-\(UUID().uuidString)")
        }
        var parked = 0, placed = 0
        do {
            for i in pairs.indices {
                try fm.moveItem(at: pairs[i].from, to: temporary[i])
                parked += 1
            }
            for i in pairs.indices {
                try fm.moveItem(at: temporary[i], to: pairs[i].to)
                placed += 1
            }
        } catch {
            for i in (0..<placed).reversed() { try? fm.moveItem(at: pairs[i].to, to: temporary[i]) }
            for i in (0..<parked).reversed() { try? fm.moveItem(at: temporary[i], to: pairs[i].from) }
            throw error
        }
    }
}
