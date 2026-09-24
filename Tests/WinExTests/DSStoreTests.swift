import Foundation
import Testing
@testable import WinEx

/// Builds a minimal Finder .DS_Store (Bud1 B-tree with one leaf node) for the parser.
enum DSStoreFixture {
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func utf16(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] } }

    enum Value { case blob([UInt8]), ustr(String) }

    static func record(_ name: String, _ structure: String, _ value: Value) -> [UInt8] {
        var bytes = be32(UInt32(name.utf16.count)) + utf16(name) + Array(structure.utf8)
        switch value {
        case .blob(let data): bytes += Array("blob".utf8) + be32(UInt32(data.count)) + data
        case .ustr(let s): bytes += Array("ustr".utf8) + be32(UInt32(s.utf16.count)) + utf16(s)
        }
        return bytes
    }

    /// Blocks (relative offsets, 2048 bytes each): 0 = root, 1 = DSDB header, 2 = leaf node.
    static func file(records: [[UInt8]]) -> Data {
        let blockSize: UInt32 = 2048, log2: UInt32 = 11
        func address(_ i: UInt32) -> UInt32 { (blockSize * (i + 1)) | log2 }
        var root = be32(3) + be32(0)
        for i in 0..<256 { root += be32(i < 3 ? address(UInt32(i)) : 0) }
        root += be32(1) + [4] + Array("DSDB".utf8) + be32(1)
        let header = be32(2) + be32(0) + be32(UInt32(records.count)) + be32(1) + be32(0x1000)
        let leaf = be32(0) + be32(UInt32(records.count)) + records.flatMap { $0 }
        var bytes = be32(1) + Array("Bud1".utf8) + be32(blockSize) + be32(blockSize) + be32(blockSize) + [UInt8](repeating: 0, count: 16)
        for block in [root, header, leaf] {
            // Each block starts at 4 + its relative offset
            bytes += [UInt8](repeating: 0, count: 4 + Int(blockSize) * ((bytes.count - 4) / Int(blockSize) + 1) - bytes.count)
            bytes += block
        }
        return Data(bytes)
    }
}

struct DSStoreTests {
    @Test func desktopPositionsAndTrashLocations() throws {
        // dilc: anchor 1 (top-right), offset (-65, 79) → icon center 65 pt from the right, 79 pt from the top
        var dilc = [UInt8](repeating: 0, count: 32)
        dilc.replaceSubrange(4..<8, with: DSStoreFixture.be32(0x0001_0000))
        dilc.replaceSubrange(8..<12, with: DSStoreFixture.be32(UInt32(bitPattern: -65)))
        dilc.replaceSubrange(12..<16, with: DSStoreFixture.be32(79))
        let data = DSStoreFixture.file(records: [
            DSStoreFixture.record("zefir-bot", "dilc", .blob(dilc)),
            DSStoreFixture.record("Отчёт.docx", "ptbL", .ustr("Users/me/Desktop/")),
            DSStoreFixture.record("Отчёт.docx", "ptbN", .ustr("Отчёт.docx")),
        ])
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try data.write(to: dir.appendingPathComponent(".DS_Store"))

        let centers = FinderDesktopLayout.iconCenters(in: dir, screenSize: CGSize(width: 1710, height: 1107))
        let zefir = try #require(centers["zefir-bot"])
        #expect(abs(zefir.x - (1710 - 65) / 1710) < 0.0001)
        #expect(abs(zefir.y - 79.0 / 1107) < 0.0001)

        var strings: [String: String] = [:]
        try FinderDesktopLayout.DSStore(bytes: [UInt8](data)).forEachRecord({ _, _, _ in }, strings: { name, structure, value in
            strings["\(name)/\(structure)"] = value
        })
        #expect(strings["Отчёт.docx/ptbL"] == "Users/me/Desktop/")
        #expect(strings["Отчёт.docx/ptbN"] == "Отчёт.docx")
    }

    @Test func garbageIsIgnoredNotFatal() throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data((0..<500).map { UInt8($0 % 251) }).write(to: dir.appendingPathComponent(".DS_Store"))
        #expect(FinderDesktopLayout.iconCenters(in: dir, screenSize: CGSize(width: 100, height: 100)).isEmpty)
    }
}
