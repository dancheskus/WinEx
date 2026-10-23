import Foundation
import Security

/// Talking to iPhones and iPads the way Finder's helpers do, without Apple's private frameworks:
/// usbmuxd (`/var/run/usbmuxd`) lists the devices (cable or Wi‑Fi) and opens a connection to a
/// port on one; lockdownd (port 62078) answers questions and starts services; a session and the
/// services it starts are wrapped in TLS with the Mac's pair record (the one Finder made at «Доверять»).
enum MobileDeviceLink {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// One device as usbmuxd lists it.
    struct Device: Equatable, Sendable {
        let id: Int
        let udid: String
        let wifi: Bool
    }

    // MARK: - Sockets

    /// A blocking socket with exact reads and writes.
    final class Socket {
        fileprivate(set) var fd: Int32

        init(fd: Int32) { self.fd = fd }

        static func usbmuxd(timeout: TimeInterval = 10) throws -> Socket {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure("socket: \(errno)") }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = "/var/run/usbmuxd"
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            let ok = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard ok == 0 else { Darwin.close(fd); throw Failure("usbmuxd isn't running") }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let socket = Socket(fd: fd)
            socket.timeout = timeout
            return socket
        }

        var timeout: TimeInterval = 10 {
            didSet {
                var value = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
            }
        }

        deinit { if fd >= 0 { Darwin.close(fd) } }

        func close() {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }

        func write(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw Failure("write: \(errno)") }
                    offset += n
                }
            }
        }

        func read(_ count: Int) throws -> Data {
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < count {
                    let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw Failure(n == 0 ? "connection closed" : "read: \(errno)") }
                    offset += n
                }
            }
            return data
        }
    }

    /// Bytes over a socket, or over TLS on it.
    protocol Channel: AnyObject {
        func write(_ data: Data) throws
        func read(_ count: Int) throws -> Data
    }

    // MARK: - usbmuxd

    private static func muxPacket(_ message: [String: Any], tag: UInt32) throws -> Data {
        var message = message
        message["ClientVersionString"] = "WinEx"
        message["ProgName"] = "WinEx"
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var header = Data()
        for value in [UInt32(16 + body.count), 1, 8, tag] { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        return header + body
    }

    private static func readMux(_ socket: Socket) throws -> [String: Any] {
        let header = try socket.read(16)
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length >= 16, length < 16 << 20 else { throw Failure("usbmuxd: bad packet") }
        let body = try socket.read(length - 16)
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else { throw Failure("usbmuxd: bad reply") }
        return plist
    }

    /// One request on a new usbmuxd connection; the connection is returned too (after `Connect` it
    /// carries the device's port).
    private static func mux(_ message: [String: Any]) throws -> (Socket, [String: Any]) {
        let socket = try Socket.usbmuxd()
        try socket.write(muxPacket(message, tag: 1))
        return (socket, try readMux(socket))
    }

    /// The devices connected now. A device on both cable and Wi‑Fi is listed once (the cable).
    static func devices() throws -> [Device] {
        let (_, reply) = try mux(["MessageType": "ListDevices"])
        let list = reply["DeviceList"] as? [[String: Any]] ?? []
        var byUDID: [String: Device] = [:]
        for entry in list {
            guard let id = entry["DeviceID"] as? Int, let properties = entry["Properties"] as? [String: Any],
                  let udid = properties["SerialNumber"] as? String else { continue }
            let device = Device(id: id, udid: udid, wifi: (properties["ConnectionType"] as? String) == "Network")
            if let known = byUDID[udid], !known.wifi { continue }
            byUDID[udid] = device
        }
        return byUDID.values.sorted { $0.udid < $1.udid }
    }

    /// Calls `changed` whenever a device comes or goes (on a background thread), until the
    /// returned socket is closed.
    static func listen(_ changed: @escaping @Sendable () -> Void) throws -> Socket {
        let socket = try Socket.usbmuxd()
        try socket.write(muxPacket(["MessageType": "Listen"], tag: 1))
        guard (try readMux(socket)["Number"] as? Int) == 0 else { throw Failure("usbmuxd: Listen refused") }
        socket.timeout = 0
        Thread.detachNewThread {
            while socket.fd >= 0, let message = try? readMux(socket) {
                if let type = message["MessageType"] as? String, type == "Attached" || type == "Detached" { changed() }
            }
        }
        return socket
    }

    struct PairRecord {
        let hostID: String
        let systemBUID: String
        let certificate: Data
        let privateKey: Data
    }

    static func pairRecord(udid: String) throws -> PairRecord {
        let (_, reply) = try mux(["MessageType": "ReadPairRecord", "PairRecordID": udid])
        guard let data = reply["PairRecordData"] as? Data,
              let record = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let hostID = record["HostID"] as? String, let buid = record["SystemBUID"] as? String,
              let certificate = record["HostCertificate"] as? Data, let key = record["HostPrivateKey"] as? Data
        else { throw Failure("not trusted") }
        return PairRecord(hostID: hostID, systemBUID: buid, certificate: certificate, privateKey: key)
    }

    /// A connection to a port on the device.
    static func connect(_ device: Device, port: UInt16) throws -> Socket {
        let (socket, reply) = try mux(["MessageType": "Connect", "DeviceID": device.id, "PortNumber": Int(port.bigEndian)])
        guard (reply["Number"] as? Int) == 0 else { throw Failure("can't reach port \(port): \(reply["Number"] ?? "?")") }
        return socket
    }
}

extension MobileDeviceLink.Socket: MobileDeviceLink.Channel {}

// MARK: - TLS

extension MobileDeviceLink {
    /// TLS over a connected socket, the Mac's pair record as the client's identity (devices
    /// accept TLS 1.2 and don't check the server name).
    final class TLS: Channel {
        private let socket: Socket
        private let context: SSLContext

        init(over socket: Socket, record: PairRecord) throws {
            self.socket = socket
            guard let context = SSLCreateContext(nil, .clientSide, .streamType) else { throw Failure("TLS: no context") }
            self.context = context
            SSLSetIOFuncs(context, { connection, data, length in
                let socket = Unmanaged<Socket>.fromOpaque(connection).takeUnretainedValue()
                let wanted = length.pointee
                var done = 0
                while done < wanted {
                    let n = Darwin.read(socket.fd, data + done, wanted - done)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { length.pointee = done; return n == 0 ? errSSLClosedGraceful : errSSLClosedAbort }
                    done += n
                }
                return noErr
            }, { connection, data, length in
                let socket = Unmanaged<Socket>.fromOpaque(connection).takeUnretainedValue()
                let wanted = length.pointee
                var done = 0
                while done < wanted {
                    let n = Darwin.write(socket.fd, data + done, wanted - done)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { length.pointee = done; return errSSLClosedAbort }
                    done += n
                }
                return noErr
            })
            SSLSetConnection(context, Unmanaged.passUnretained(socket).toOpaque())
            SSLSetSessionOption(context, .breakOnServerAuth, true)
            SSLSetProtocolVersionMin(context, .tlsProtocol1)
            let identity = try Self.identity(record)
            guard SSLSetCertificate(context, [identity] as CFArray) == noErr else { throw Failure("TLS: certificate refused") }
            var status: OSStatus
            repeat { status = SSLHandshake(context) } while status == errSSLPeerAuthCompleted || status == errSSLWouldBlock
            guard status == noErr else { throw Failure("TLS handshake: \(status)") }
        }

        deinit { SSLClose(context) }

        func write(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    var written = 0
                    let status = SSLWrite(context, raw.baseAddress! + offset, raw.count - offset, &written)
                    guard status == noErr || (status == errSSLWouldBlock && written > 0) else { throw Failure("TLS write: \(status)") }
                    offset += written
                }
            }
        }

        func read(_ count: Int) throws -> Data {
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < count {
                    var got = 0
                    let status = SSLRead(context, raw.baseAddress! + offset, count - offset, &got)
                    guard status == noErr || (status == errSSLWouldBlock && got > 0) else { throw Failure("TLS read: \(status)") }
                    offset += got
                }
            }
            return data
        }

        /// The pair record's certificate and key as one identity, without the keychain.
        private static func identity(_ record: PairRecord) throws -> SecIdentity {
            guard let certificateDER = derFromPEM(record.certificate),
                  let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
                  let keyDER = derFromPEM(record.privateKey) else { throw Failure("pair record: bad certificate") }
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
            guard let key = SecKeyCreateWithData((rsaKey(fromPKCS8: keyDER) ?? keyDER) as CFData, attributes as CFDictionary, nil)
            else { throw Failure("pair record: bad key") }
            // Security's SecIdentityCreate pairs them in memory (what the keychain does on lookup)
            typealias Create = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecIdentityCreate"),
                  let identity = unsafeBitCast(symbol, to: Create.self)(nil, certificate, key)?.takeRetainedValue()
            else { throw Failure("pair record: no identity") }
            return identity
        }

        static func derFromPEM(_ pem: Data) -> Data? {
            guard let text = String(data: pem, encoding: .ascii) else { return nil }
            let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
            return Data(base64Encoded: body)
        }

        /// PKCS#8 → PKCS#1: SEQUENCE { INTEGER, SEQUENCE { algorithm }, OCTET STRING { RSA key } }.
        static func rsaKey(fromPKCS8 der: Data) -> Data? {
            let bytes = [UInt8](der)
            var i = 0
            func header() -> (tag: UInt8, length: Int)? {
                guard i + 2 <= bytes.count else { return nil }
                let tag = bytes[i]
                var length = Int(bytes[i + 1])
                i += 2
                if length & 0x80 != 0 {
                    let count = length & 0x7f
                    guard count <= 4, i + count <= bytes.count else { return nil }
                    length = bytes[i..<i + count].reduce(0) { $0 << 8 | Int($1) }
                    i += count
                }
                return (tag, length)
            }
            guard header()?.tag == 0x30, let version = header(), version.tag == 0x02 else { return nil }
            i += version.length
            guard let algorithm = header(), algorithm.tag == 0x30 else { return nil }
            i += algorithm.length
            guard let key = header(), key.tag == 0x04, i + key.length <= bytes.count else { return nil }
            return Data(bytes[i..<i + key.length])
        }
    }
}

// MARK: - lockdownd and services

extension MobileDeviceLink {
    /// Plist messages, each after its big-endian length (lockdownd, installation_proxy, house_arrest).
    final class PlistService {
        let channel: Channel
        /// Kept alive for the TLS that runs over it.
        private let socket: Socket

        init(socket: Socket, channel: Channel? = nil) {
            self.socket = socket
            self.channel = channel ?? socket
        }

        func send(_ message: [String: Any]) throws {
            let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
            var length = UInt32(body.count).bigEndian
            try channel.write(Data(bytes: &length, count: 4) + body)
        }

        func receive() throws -> [String: Any] {
            let length = Int(try channel.read(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard length < 64 << 20 else { throw Failure("message too large") }
            guard let plist = try PropertyListSerialization.propertyList(from: try channel.read(length), format: nil) as? [String: Any]
            else { throw Failure("bad message") }
            return plist
        }

        func request(_ message: [String: Any]) throws -> [String: Any] {
            try send(message)
            let reply = try receive()
            if let error = reply["Error"] as? String { throw Failure(error) }
            return reply
        }
    }

    /// lockdownd on a device: values before a session (name, model, version), more after one.
    final class Lockdown {
        let device: Device
        private var service: PlistService
        private var record: PairRecord?

        init(_ device: Device) throws {
            self.device = device
            service = PlistService(socket: try MobileDeviceLink.connect(device, port: 62078))
            _ = try service.request(["Request": "QueryType", "Label": "WinEx"])
        }

        func value(_ key: String? = nil, domain: String? = nil) throws -> Any? {
            var message: [String: Any] = ["Request": "GetValue", "Label": "WinEx"]
            if let key { message["Key"] = key }
            if let domain { message["Domain"] = domain }
            return try service.request(message)["Value"]
        }

        /// A session with the pair record; values of every domain and services after it.
        func startSession() throws {
            let record = try MobileDeviceLink.pairRecord(udid: device.udid)
            let reply = try service.request(["Request": "StartSession", "Label": "WinEx", "HostID": record.hostID, "SystemBUID": record.systemBUID])
            self.record = record
            if reply["EnableSessionSSL"] as? Bool == true, let socket = service.socketForTLS {
                service = PlistService(socket: socket, channel: try TLS(over: socket, record: record))
            }
        }

        /// Starts a service and connects to it (in TLS if it asks for it).
        func startService(_ name: String) throws -> PlistService {
            let reply = try service.request(["Request": "StartService", "Label": "WinEx", "Service": name])
            guard let port = reply["Port"] as? Int else { throw Failure("\(name) didn't start") }
            let socket = try MobileDeviceLink.connect(device, port: UInt16(port))
            if reply["EnableServiceSSL"] as? Bool == true, let record {
                return PlistService(socket: socket, channel: try TLS(over: socket, record: record))
            }
            return PlistService(socket: socket)
        }
    }
}

private extension MobileDeviceLink.PlistService {
    /// The plain socket, for a session's TLS to be put on.
    var socketForTLS: MobileDeviceLink.Socket? { channel as? MobileDeviceLink.Socket }
}
