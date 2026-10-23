import Foundation
import Testing
@testable import WinEx

struct MountTableTests {
    @Test func shareAddressesFromTheMountTable() {
        #expect(MountTable.remountURL(type: "smbfs", from: "//dancheskus@NAS._smb._tcp.local/Daniel")?.absoluteString
                == "smb://dancheskus@NAS._smb._tcp.local/Daniel")
        #expect(MountTable.remountURL(type: "smbfs", from: "//user@192.168.1.10/My%20Files")?.absoluteString
                == "smb://user@192.168.1.10/My%20Files")
        #expect(MountTable.remountURL(type: "afpfs", from: "//user;AUTH=No%20User%20Authent@nas.local/Home")?.absoluteString
                == "afp://user@nas.local/Home")
        #expect(MountTable.remountURL(type: "nfs", from: "nas.local:/volume1/media")?.absoluteString
                == "nfs://nas.local/volume1/media")
        #expect(MountTable.remountURL(type: "webdav", from: "https://dav.example.com/files")?.absoluteString
                == "https://dav.example.com/files")
        // The server and the share come out as the rest of WinEx reads them
        let share = MountTable.remountURL(type: "smbfs", from: "//dancheskus@NAS._smb._tcp.local/Daniel")
        #expect(share.flatMap(Places.serverRoot)?.absoluteString == "smb://NAS._smb._tcp.local")
        #expect(share.map(Places.shareName(of:)) == "Daniel")
    }

    @Test func listsNoLocalDisks() {
        // Whatever is mounted here, the startup disk isn't a network share
        #expect(!MountTable.networkMounts().contains { $0.volume.path == "/" })
    }
}
