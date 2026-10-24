import Foundation
import Testing
@testable import WinEx

struct BatchRenameTests {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: "/tmp/batch")

    func items(_ names: [String], folders: Set<String> = []) -> [BatchRename.Item] {
        names.map { BatchRename.Item(url: dir.appendingPathComponent($0), isFolder: folders.contains($0)) }
    }

    func names(_ names: [String], folders: Set<String> = [], existing: [String] = [], _ change: (inout BatchRenameRules) -> Void) -> [String] {
        outcomes(names, folders: folders, existing: existing, change).map(\.newName)
    }

    func outcomes(_ names: [String], folders: Set<String> = [], existing: [String] = [], _ change: (inout BatchRenameRules) -> Void) -> [BatchRename.Outcome] {
        var rules = BatchRenameRules()
        change(&rules)
        let all = Set((names + existing).map { $0.lowercased() })
        return BatchRename.preview(items(names, folders: folders), rules: rules, existing: [dir.path: all])
    }

    @Test func emptyRulesChangeNothing() {
        let result = outcomes(["a.txt", "b"]) { _ in }
        #expect(result.map(\.newName) == ["a.txt", "b"] && result.allSatisfy { !$0.changes && $0.problem == nil })
    }

    @Test func replacesTextButNotTheExtension() {
        #expect(names(["IMG_txt.txt", "img_2.TXT"]) { $0.find = "img_"; $0.replaceWith = "Фото " } == ["Фото txt.txt", "Фото 2.TXT"])
        #expect(names(["IMG_1.jpg", "img_2.jpg"]) { $0.find = "IMG_"; $0.matchCase = true } == ["1.jpg", "img_2.jpg"])
        #expect(names(["a.txt"]) { $0.find = "txt"; $0.replaceWith = "doc" } == ["a.txt"])
    }

    @Test func numbersWithLeadingZerosFromTheCount() {
        let twelve = (1...12).map { "f\($0).jpg" }
        let result = names(twelve) { $0.newName = "Отпуск"; $0.numbering = .end }
        #expect(result.first == "Отпуск 01.jpg" && result.last == "Отпуск 12.jpg")
        #expect(names(["a", "b"]) { $0.numbering = .start; $0.separator = .underscore; $0.startNumber = 9 } == ["09_a", "10_b"])
        #expect(names(["a", "b"]) { $0.numbering = .end; $0.separator = .parentheses } == ["a (1)", "b (2)"])
        #expect(names(["a"]) { $0.numbering = .end; $0.digits = 3; $0.separator = .dash } == ["a-001"])
    }

    @Test func removesOldNumbersToNumberAnew() {
        #expect(names(["Тест 1", "Тест 10", "01-Отчёт.txt", "Фото (2).jpg", "IMG_0042.JPG", "2026"]) { $0.removeNumbers = true }
                == ["Тест", "Тест", "Отчёт.txt", "Фото.jpg", "IMG.JPG", ""])
        #expect(names(["Тест 1.txt", "Тест 10.txt"]) { $0.removeNumbers = true; $0.numbering = .start }
                == ["1 Тест.txt", "2 Тест.txt"])
        // Saved by a version without this step
        let old = try? JSONDecoder().decode(BatchRenameRules.self, from: Data(#"{"find":"a","numbering":"end"}"#.utf8))
        #expect(old?.find == "a" && old?.numbering == .end && old?.removeNumbers == false && old?.startNumber == 1)
    }

    @Test func addsCaseAndKeepsFolderDots() {
        #expect(names(["мой отчёт.PDF"]) { $0.textCase = .words; $0.prefix = "2026 " } == ["2026 Мой Отчёт.PDF"])
        #expect(names(["Документ 1.txt"]) { $0.textCase = .upper; $0.prefix = "Проверочный "; $0.numbering = .start; $0.separator = .dash } == ["1-ПРОВЕРОЧНЫЙ ДОКУМЕНТ 1.txt"])
        #expect(names(["ПРИВЕТ МИР.txt"]) { $0.textCase = .sentence } == ["Привет мир.txt"])
        #expect(names(["v1.2"], folders: ["v1.2"]) { $0.suffix = " final" } == ["v1.2 final"])
        #expect(names(["Some.app"]) { $0.textCase = .upper } == ["SOME.app"])
    }

    @Test func conflicts() {
        #expect(outcomes(["a.txt", "b.txt"]) { $0.newName = "x" }.map(\.problem) == [.duplicate, .duplicate])
        #expect(outcomes(["a.txt"], existing: ["X.txt"]) { $0.newName = "x" }.first?.problem == .exists)
        #expect(outcomes(["a.txt"]) { $0.find = "a" }.first?.problem == .empty)
        #expect(outcomes(["a.txt"]) { $0.suffix = "/b" }.first?.problem == .invalidCharacters)
        #expect(outcomes(["a.txt"]) { $0.prefix = "." }.first?.problem == .hidden)
        #expect(outcomes(["a.txt"]) { $0.suffix = String(repeating: "я", count: 130) }.first?.problem == .tooLong)
        // Becomes the name of another one that stays: only the one changing is marked
        #expect(outcomes(["a", "b"]) { $0.find = "a"; $0.replaceWith = "b" }.map(\.problem) == [.duplicate, nil])
        // Taken by an item that's being renamed itself: fine (f 1→f 2, f 2→f 3)
        let chain = outcomes(["f 1", "f 2"]) { $0.newName = "f"; $0.numbering = .end; $0.startNumber = 2 }
        #expect(chain.map(\.newName) == ["f 2", "f 3"] && chain.allSatisfy { $0.problem == nil })
    }

    @Test func performSwapsChainsAndCaseOnly() throws {
        let folder = tempFolder()
        defer { try? fm.removeItem(at: folder) }
        for name in ["a", "b", "c.txt"] { fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(name.utf8)) }
        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
        try BatchRename.perform([(url("a"), url("b")), (url("b"), url("a")), (url("c.txt"), url("C.txt"))])
        #expect(String(data: fm.contents(atPath: url("b").path) ?? Data(), encoding: .utf8) == "a")
        #expect(String(data: fm.contents(atPath: url("a").path) ?? Data(), encoding: .utf8) == "b")
        #expect(try fm.contentsOfDirectory(atPath: folder.path).sorted() == ["C.txt", "a", "b"])
    }

    @Test func performPutsEverythingBackOnError() throws {
        let folder = tempFolder()
        defer { try? fm.removeItem(at: folder) }
        for name in ["a", "b", "taken"] { fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil) }
        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
        #expect(throws: (any Error).self) { try BatchRename.perform([(url("a"), url("x")), (url("b"), url("taken"))]) }
        #expect(try fm.contentsOfDirectory(atPath: folder.path).sorted() == ["a", "b", "taken"])
    }
}
