import Foundation
import Testing
@testable import WinEx

struct FileOperationTests {
    let fm = FileManager.default

    func make(_ dir: URL, _ name: String, bytes: Int = 10) -> URL {
        let url = dir.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
        return url
    }

    func contents(_ dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func copiesFilesAndFoldersWithProgress() throws {
        let (from, to) = (tempFolder(), tempFolder())
        defer { [from, to].forEach { try? fm.removeItem(at: $0) } }
        let file = make(from, "big.file", bytes: 3_000_000)
        let folder = from.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = make(folder, "a.txt", bytes: 100)
        _ = make(folder, "b.txt", bytes: 200)

        let operation = FileOperation(kind: .copy, sources: [file, folder], destination: to)
        var finished: FileOperation.Result?
        operation.onFinish = { finished = $0 }
        operation.run()
        let progress = operation.progress
        #expect(progress.totalBytes == 3_000_300 && progress.doneBytes == progress.totalBytes)
        #expect(progress.totalItems == 3 && progress.doneItems == 3)
        #expect(contents(to) == ["big.file", "folder"] && contents(to.appendingPathComponent("folder")) == ["a.txt", "b.txt"])
        #expect(finished?.done.count == 2 && finished?.cancelled == false)
        #expect(contents(from) == ["big.file", "folder"])  // copies leave the originals
    }

    @Test(arguments: [FileOperation.Resolution.replace, .skip, .keepBoth])
    func nameConflicts(_ resolution: FileOperation.Resolution) throws {
        let (from, to) = (tempFolder(), tempFolder())
        defer { [from, to].forEach { try? fm.removeItem(at: $0) } }
        let source = make(from, "report.txt", bytes: 5)
        _ = make(to, "report.txt", bytes: 99)
        _ = make(from, "new.txt")

        let operation = FileOperation(kind: .copy, sources: [source, from.appendingPathComponent("new.txt")], destination: to)
        operation.trashReplacedItems = false
        var asked: [String] = []
        operation.decideConflicts = { conflicts in
            asked = conflicts.map(\.source.lastPathComponent)
            return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, resolution) })
        }
        operation.run()
        #expect(asked == ["report.txt"])
        let size = (try? fm.attributesOfItem(atPath: to.appendingPathComponent("report.txt").path)[.size] as? Int) ?? -1
        switch resolution {
        case .replace: #expect(size == 5 && contents(to) == ["new.txt", "report.txt"])
        case .skip: #expect(size == 99 && contents(to) == ["new.txt", "report.txt"])
        case .keepBoth: #expect(size == 99 && contents(to) == ["new.txt", "report - копия.txt", "report.txt"])
        }
    }

    @Test func noAnswerCancelsEverything() {
        let (from, to) = (tempFolder(), tempFolder())
        defer { [from, to].forEach { try? fm.removeItem(at: $0) } }
        let source = make(from, "x.txt")
        _ = make(to, "x.txt")
        let operation = FileOperation(kind: .copy, sources: [source], destination: to)
        operation.decideConflicts = { _ in nil }  // the dialog was closed
        var finished: FileOperation.Result?
        operation.onFinish = { finished = $0 }
        operation.run()
        #expect(finished?.cancelled == true && finished?.done.isEmpty == true)
    }

    @Test func movesWithinAVolumeAreRenames() {
        let (from, to) = (tempFolder(), tempFolder())
        defer { [from, to].forEach { try? fm.removeItem(at: $0) } }
        let source = make(from, "m.txt")
        let operation = FileOperation(kind: .move, sources: [source], destination: to)
        operation.run()
        #expect(contents(from).isEmpty && contents(to) == ["m.txt"])
        #expect(operation.progress.byBytes == false && operation.progress.fraction == 1)
    }

    @Test func copyIntoItsOwnFolderMakesACopy() {
        let dir = tempFolder()
        defer { try? fm.removeItem(at: dir) }
        let source = make(dir, "doc.txt")
        let operation = FileOperation(kind: .copy, sources: [source], destination: dir)
        operation.decideConflicts = { _ in Issue.record("no question expected"); return nil }
        operation.run()
        #expect(contents(dir) == ["doc - копия.txt", "doc.txt"])
    }

    @Test func folderIntoItselfIsAnError() throws {
        let dir = tempFolder()
        defer { try? fm.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("f")
        try fm.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let operation = FileOperation(kind: .copy, sources: [folder], destination: folder.appendingPathComponent("inner"))
        var errors = 0
        operation.onError = { _, _ in errors += 1; return .skip }
        operation.run()
        #expect(errors == 1 && contents(folder.appendingPathComponent("inner")).isEmpty)
    }

    @Test func cancelStopsAndLeavesNoHalfCopy() {
        let (from, to) = (tempFolder(), tempFolder())
        defer { [from, to].forEach { try? fm.removeItem(at: $0) } }
        let sources = (1...5).map { make(from, "f\($0).bin", bytes: 1000) }
        let operation = FileOperation(kind: .copy, sources: sources, destination: to)
        operation.cancel()
        var finished: FileOperation.Result?
        operation.onFinish = { finished = $0 }
        operation.run()
        #expect(finished?.cancelled == true && contents(to).isEmpty)
    }

    @Test func deleteRemovesAndCountsItems() {
        let dir = tempFolder()
        defer { try? fm.removeItem(at: dir) }
        let files = (1...3).map { make(dir, "d\($0)") }
        let operation = FileOperation(kind: .delete, sources: files)
        operation.run()
        #expect(contents(dir).isEmpty && operation.progress.doneItems == 3 && operation.progress.fraction == 1)
    }
}
