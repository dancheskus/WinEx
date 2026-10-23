import Foundation

extension MobileDeviceLink {
    /// Apple File Conduit: a device's files over a service connection (`com.apple.afc` — the
    /// media folder with DCIM; house_arrest's VendDocuments — an app's Documents).
    final class AFC {
        struct Entry: Sendable {
            let name: String
            let path: String
            let isDirectory: Bool
            let size: Int64
            let modified: Date?
            let created: Date?
        }

        /// The device refused (no such file, not empty…): the connection is still good.
        struct Refusal: Error, CustomStringConvertible {
            let code: UInt64
            var description: String {
                switch code {
                case 8: L("Объект не найден.")
                case 10: L("Нет доступа.")
                case 16: L("Объект с таким именем уже существует.")
                case 17, 18: L("Папка не пуста.")
                default: L("Устройство не выполнило действие (код %@).", String(code))
                }
            }
        }

        private enum Operation: UInt64 {
            case status = 0x01, data = 0x02, readDirectory = 0x03, removePath = 0x08, makeDirectory = 0x09
            case fileInfo = 0x0A, fileOpen = 0x0D, fileOpenResult = 0x0E, fileRead = 0x0F, fileWrite = 0x10
            case fileClose = 0x14, renamePath = 0x18, removePathAndContents = 0x22
        }

        private let service: PlistService
        private var packet: UInt64 = 0
        private let lock = NSLock()

        init(_ service: PlistService) { self.service = service }

        private static func u64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        private static func cString(_ text: String) -> Data { Data(text.utf8) + [0] }

        /// Sends one request, returns its reply's header data and payload.
        private func call(_ operation: Operation, _ header: Data = Data(), payload: Data = Data()) throws -> (op: UInt64, header: Data, payload: Data) {
            lock.lock()
            defer { lock.unlock() }
            packet += 1
            let thisLength = UInt64(40 + header.count)
            var data = Data("CFA6LPAA".utf8)
            data += Self.u64(thisLength + UInt64(payload.count)) + Self.u64(thisLength) + Self.u64(packet) + Self.u64(operation.rawValue)
            try service.channel.write(data + header + payload)
            let reply = try service.channel.read(40)
            guard reply.prefix(8) == Data("CFA6LPAA".utf8) else { throw Failure("AFC: bad reply") }
            func field(_ offset: Int) -> UInt64 { reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.littleEndian }
            let entire = Int(field(8)), this = Int(field(16)), op = field(32)
            guard this >= 40, entire >= this, entire < 1 << 31 else { throw Failure("AFC: bad lengths") }
            let replyHeader = this > 40 ? try service.channel.read(this - 40) : Data()
            let replyPayload = entire > this ? try service.channel.read(entire - this) : Data()
            if op == Operation.status.rawValue {
                let code = replyHeader.count >= 8 ? replyHeader.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian : 0
                if code != 0 { throw Refusal(code: code) }
            }
            return (op, replyHeader, replyPayload)
        }

        private static func strings(_ data: Data) -> [String] {
            data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
        }

        func list(_ path: String) throws -> [String] {
            let (_, header, payload) = try call(.readDirectory, Self.cString(path))
            return Self.strings(payload.isEmpty ? header : payload).filter { $0 != "." && $0 != ".." }
        }

        func info(_ path: String) throws -> Entry {
            let (_, header, payload) = try call(.fileInfo, Self.cString(path))
            let parts = Self.strings(payload.isEmpty ? header : payload)
            var values: [String: String] = [:]
            stride(from: 0, to: parts.count - 1, by: 2).forEach { values[parts[$0]] = parts[$0 + 1] }
            func date(_ key: String) -> Date? { values[key].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1e9) } }
            return Entry(name: (path as NSString).lastPathComponent, path: path, isDirectory: values["st_ifmt"] == "S_IFDIR",
                         size: values["st_size"].flatMap(Int64.init) ?? 0, modified: date("st_mtime"), created: date("st_birthtime"))
        }

        /// A folder's items with their details.
        func entries(_ path: String) throws -> [Entry] {
            try list(path).compactMap { name in
                try? info(path == "/" ? "/" + name : path + "/" + name)
            }
        }

        /// A folder's contents, folders inside it too, as (device path, path relative to `path`).
        func walk(_ path: String) throws -> [(entry: Entry, relative: String)] {
            var result: [(Entry, String)] = []
            func visit(_ folder: String, _ relative: String) throws {
                for entry in try entries(folder) {
                    let inner = relative.isEmpty ? entry.name : relative + "/" + entry.name
                    result.append((entry, inner))
                    if entry.isDirectory { try visit(entry.path, inner) }
                }
            }
            try visit(path, "")
            return result
        }

        func makeDirectory(_ path: String) throws { _ = try call(.makeDirectory, Self.cString(path)) }
        func remove(_ path: String) throws { _ = try call(.removePathAndContents, Self.cString(path)) }
        func rename(_ path: String, to newPath: String) throws { _ = try call(.renamePath, Self.cString(path) + Self.cString(newPath)) }

        private func open(_ path: String, mode: UInt64) throws -> UInt64 {
            let (op, header, _) = try call(.fileOpen, Self.u64(mode) + Self.cString(path))
            guard op == Operation.fileOpenResult.rawValue, header.count >= 8 else { throw Failure("AFC: can't open \(path)") }
            return header.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }

        private func close(_ handle: UInt64) { _ = try? call(.fileClose, Self.u64(handle)) }

        /// A small file's bytes (a thumbnail).
        func data(_ path: String) throws -> Data {
            let handle = try open(path, mode: 1)
            defer { close(handle) }
            var result = Data()
            while true {
                let (_, _, chunk) = try call(.fileRead, Self.u64(handle) + Self.u64(1 << 20))
                if chunk.isEmpty { break }
                result += chunk
            }
            return result
        }

        /// Copies a device file to `destination` in chunks; `progress` gets the bytes done so far
        /// and returns false to stop.
        func download(_ path: String, to destination: URL, progress: (Int64) -> Bool = { _ in true }) throws {
            let handle = try open(path, mode: 1)
            defer { close(handle) }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            var done: Int64 = 0
            while true {
                let (_, _, chunk) = try call(.fileRead, Self.u64(handle) + Self.u64(1 << 20))
                if chunk.isEmpty { break }
                try file.write(contentsOf: chunk)
                done += Int64(chunk.count)
                guard progress(done) else { throw CancellationError() }
            }
        }

        /// Copies a Mac file onto the device (replacing a file of that name).
        func upload(_ source: URL, to path: String, progress: (Int64) -> Bool = { _ in true }) throws {
            let handle = try open(path, mode: 3)
            defer { close(handle) }
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            var done: Int64 = 0
            while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
                _ = try call(.fileWrite, Self.u64(handle), payload: chunk)
                done += Int64(chunk.count)
                guard progress(done) else { throw CancellationError() }
            }
        }
    }
}
