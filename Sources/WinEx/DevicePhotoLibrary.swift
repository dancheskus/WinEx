import Foundation
import SQLite3

/// What the device's Photos library says of the files in DCIM (PhotoData/Photos.sqlite): DCIM also
/// keeps «Недавно удалённые» for 30 days and the hidden ones, which the library doesn't show.
enum DevicePhotoLibrary {
    struct Asset: Sendable {
        let isVideo: Bool
        let isLive: Bool
        let isScreenshot: Bool
    }

    private static let files = ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"]

    /// The library's shown assets by their DCIM path, uppercased («/DCIM/113APPLE/IMG_3147.HEIC»);
    /// nil when the library can't be read (then everything in DCIM is shown). On the store's queue.
    static func shown(_ afc: MobileDeviceLink.AFC, udid: String) -> [String: Asset]? {
        let manager = FileManager.default
        let cache = DevicePreview.cacheFolder(udid).appendingPathComponent("PhotoData")
        let work = manager.temporaryDirectory.appendingPathComponent("WinEx-Photos-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: work) }
        do {
            try manager.createDirectory(at: cache, withIntermediateDirectories: true)
            // The copy kept is fetched again only when the device's has changed (31 MB on an iPhone)
            for name in files {
                let local = cache.appendingPathComponent(name)
                guard let remote = try? afc.info("/PhotoData/" + name) else {
                    try? manager.removeItem(at: local)
                    continue
                }
                let attributes = try? manager.attributesOfItem(atPath: local.path)
                if (attributes?[.size] as? NSNumber)?.int64Value == remote.size,
                   let date = attributes?[.modificationDate] as? Date, let modified = remote.modified,
                   abs(date.timeIntervalSince(modified)) < 1 { continue }
                try? manager.removeItem(at: local)
                try afc.download("/PhotoData/" + name, to: local)
                if let modified = remote.modified { try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: local.path) }
            }
            // SQLite folds the journal into the database as it closes it: it works on a copy (a clone)
            try manager.createDirectory(at: work, withIntermediateDirectories: true)
            for name in files where manager.fileExists(atPath: cache.appendingPathComponent(name).path) {
                try manager.copyItem(at: cache.appendingPathComponent(name), to: work.appendingPathComponent(name))
            }
        } catch {
            MobileDevices.log.info("\(udid, privacy: .public): no photo library: \(String(describing: error), privacy: .public)")
            return nil
        }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(work.appendingPathComponent(files[0]).path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        // ZKIND 1 is a video; ZKINDSUBTYPE 2 a Live Photo, 10 a screenshot
        let query = "SELECT ZDIRECTORY, ZFILENAME, ZKIND, ZKINDSUBTYPE FROM ZASSET WHERE ZTRASHEDSTATE = 0 AND ZHIDDEN = 0"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        var assets: [String: Asset] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let directory = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { continue }
            let subtype = sqlite3_column_int(statement, 3)
            assets[("/" + String(cString: directory) + "/" + String(cString: name)).uppercased()] =
                Asset(isVideo: sqlite3_column_int(statement, 2) == 1, isLive: subtype == 2, isScreenshot: subtype == 10)
        }
        return assets
    }
}
