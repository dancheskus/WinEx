import AppKit
import ApplicationServices
import Network
import UniformTypeIdentifiers
import os

/// iPhones and iPads connected by cable or over Wi‑Fi (the ones this Mac was trusted by), for the
/// sidebar and the device page. Finder's own device page can't be shown in another app (its
/// service only serves Apple's apps), so WinEx talks to the devices itself (`MobileDeviceLink`).
@MainActor
final class MobileDevices {
    static let shared = MobileDevices()
    static let didChange = Notification.Name("WinExMobileDevicesChanged")
    /// `log show --predicate 'subsystem == "dev.winex.WinEx" && category == "devices"' --info`
    nonisolated static let log = Logger(subsystem: "dev.winex.WinEx", category: "devices")

    struct Device: Equatable {
        let udid: String
        var name: String
        /// «iPhone17,1»
        let productType: String
        var version: String
        let deviceClass: String
        var wifi: Bool
        /// Gone from usbmuxd a moment ago (a phone over Wi‑Fi asleep): kept a while, greyed.
        var away = false
        /// Not on the network, but Finder keeps it (shown over Wi‑Fi, it wakes it up): always listed.
        var remembered = false

        /// «iPhone 16 Pro», from the system's device types (as Finder names it).
        var modelName: String { MobileDevices.modelType(productType)?.localizedDescription ?? productType }

        var symbol: String {
            switch deviceClass {
            case "iPad": "ipad"
            case "iPod": "ipodtouch"
            case "Watch": "applewatch"
            default: "iphone"
            }
        }

        /// The device's picture (the one Finder shows on its page).
        var image: NSImage {
            MobileDevices.modelType(productType).map { NSWorkspace.shared.icon(for: $0) }
                ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        }
    }

    private(set) var devices: [Device] = []
    private var listener: MobileDeviceLink.Socket?
    private var started = false
    /// When each device left usbmuxd; dropped from the list a while after.
    private var awaySince: [String: Date] = [:]
    private var pruneTimer: Timer?
    /// Wi‑Fi addresses of the devices advertising themselves on the network now (asleep ones
    /// too: Finder shows these and wakes them up); nil — can't be told (browsing not allowed).
    private var nearby: Set<String>? = []
    private var browser: NWBrowser?
    private static let awayGrace: TimeInterval = 120

    /// Everything that talks to devices, one thing at a time (a device answers one request per connection).
    nonisolated static let queue = DispatchQueue(label: "dev.winex.devices")

    func device(_ udid: String) -> Device? { devices.first { $0.udid == udid } }

    nonisolated static func modelType(_ productType: String) -> UTType? {
        UTType(tag: productType, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
    }

    /// Starts following devices (once; the sidebar asks for them as it's built).
    func start() {
        guard !started else { return }
        started = true
        listen()
        browseNearby()
    }

    /// Devices Finder can wake over Wi‑Fi are listed while they advertise themselves, as Finder does
    /// (one with a wake-up token that's elsewhere isn't).
    private func browseNearby() {
        let browser = NWBrowser(for: .bonjour(type: "_apple-mobdev2._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let addresses = Set(results.compactMap { result -> String? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return name.split(separator: "@").first.map { $0.lowercased() }
            })
            DispatchQueue.main.async {
                guard MobileDevices.shared.nearby != addresses else { return }
                MobileDevices.shared.nearby = addresses
                MobileDevices.shared.refresh()
            }
        }
        browser.stateUpdateHandler = { state in
            guard case .failed = state else { return }
            DispatchQueue.main.async {
                Self.log.info("nearby: browsing failed")
                MobileDevices.shared.nearby = nil
                MobileDevices.shared.refresh()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func listen() {
        do {
            listener = try MobileDeviceLink.listen { DispatchQueue.main.async { MobileDevices.shared.refresh() } }
            refresh()
        } catch {
            Self.log.info("usbmuxd: \(String(describing: error), privacy: .public)")
            // No usbmuxd yet: try again later
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.listen() }
        }
    }

    private var refreshing = false
    private var refreshAgain = false

    /// Reads the list again; every device on the network is asked its name and version (renamed or
    /// updated since: an update restarts it, a phone over Wi‑Fi is back within `awayGrace`).
    func refresh() {
        guard !refreshing else { return refreshAgain = true }
        refreshing = true
        let known = Dictionary(devices.map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a })
        let names = Self.knownNames
        let nearby = nearby
        Self.queue.async {
            let listed: [MobileDeviceLink.Device]
            do { listed = try MobileDeviceLink.devices() } catch {
                Self.log.info("usbmuxd list: \(String(describing: error), privacy: .public)")
                listed = []
            }
            var present: [Device] = []
            for entry in listed {
                if var device = known[entry.udid], !device.remembered {
                    device.wifi = entry.wifi
                    device.away = false
                    // Not answering this time: as it was
                    if let lockdown = try? MobileDeviceLink.Lockdown(entry) {
                        if let name = (try? lockdown.value("DeviceName")) as? String { device.name = name }
                        if let version = (try? lockdown.value("ProductVersion")) as? String { device.version = version }
                    }
                    present.append(device)
                    continue
                }
                do {
                    let lockdown = try MobileDeviceLink.Lockdown(entry)
                    // A locked device answers only in a session (one this Mac was trusted for)
                    try? lockdown.startSession()
                    present.append(Device(udid: entry.udid,
                                          name: try lockdown.value("DeviceName") as? String ?? "iPhone",
                                          productType: try lockdown.value("ProductType") as? String ?? "",
                                          version: try lockdown.value("ProductVersion") as? String ?? "",
                                          deviceClass: try lockdown.value("DeviceClass") as? String ?? "iPhone",
                                          wifi: entry.wifi))
                } catch {
                    Self.log.info("\(entry.udid, privacy: .public): \(String(describing: error), privacy: .public)")
                    // Listed but not answering yet: shown as Finder knows it
                    // (still `remembered`: asked again at the next look)
                    if var device = Self.rememberedDevice(entry.udid, names: names) {
                        device.wifi = entry.wifi
                        device.away = false
                        present.append(device)
                    }
                }
            }
            // The ones Finder shows over Wi‑Fi while they're asleep or away
            let remembered = Self.finderWiFiDevices.filter { udid in !present.contains { $0.udid == udid } }
                .filter { udid in
                    guard let nearby, let address = MobileDeviceLink.wifiAddress(udid: udid) else { return true }
                    return nearby.contains(address)
                }
                .compactMap { Self.rememberedDevice($0, names: names) }
            DispatchQueue.main.async { self.apply(present, remembered: remembered) }
        }
    }

    private func apply(_ present: [Device], remembered: [Device]) {
        refreshing = false
        let now = Date()
        var list = present
        // Names seen are kept for when the device is away (Finder's own list can't be read)
        var names = Self.knownNames
        for device in present { names[device.udid] = device.name }
        if names != Self.knownNames { AppDefaults.store.set(names, forKey: Self.namesKey) }
        var versions = Self.knownVersions
        for device in present where !device.remembered && !device.version.isEmpty { versions[device.udid] = device.version }
        if versions != Self.knownVersions { AppDefaults.store.set(versions, forKey: Self.versionsKey) }
        for device in devices where !device.remembered && !present.contains(where: { $0.udid == device.udid }) {
            let since = awaySince[device.udid] ?? now
            awaySince[device.udid] = since
            // A phone over Wi‑Fi drops off while asleep and comes back: kept a while
            guard device.wifi, now.timeIntervalSince(since) < Self.awayGrace else { continue }
            var away = device
            away.away = true
            list.append(away)
        }
        for device in present { awaySince[device.udid] = nil }
        list += remembered.filter { device in !list.contains { $0.udid == device.udid } }
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if list != devices {
            devices = list
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        learnNamesFromFinder()
        pruneTimer?.invalidate()
        // Someone away or not answering: looked for again now and then (asleep phones come back
        // without usbmuxd always saying so)
        if list.contains(where: { $0.away || $0.remembered }) {
            let soon = list.contains { $0.away && !$0.remembered }
            pruneTimer = .scheduledTimer(withTimeInterval: soon ? 15 : 30, repeats: false) { _ in
                DispatchQueue.main.async { MobileDevices.shared.refresh() }
            }
        }
        if refreshAgain {
            refreshAgain = false
            refresh()
        }
    }

    private static let namesKey = "deviceNames"
    nonisolated private static let versionsKey = "deviceVersions"

    /// Device names WinEx has seen, by UDID.
    private static var knownNames: [String: String] {
        AppDefaults.store.dictionary(forKey: namesKey) as? [String: String] ?? [:]
    }

    /// The versions WinEx saw last, by UDID (Finder's are only as new as its own last look).
    nonisolated private static var knownVersions: [String: String] {
        AppDefaults.store.dictionary(forKey: versionsKey) as? [String: String] ?? [:]
    }

    /// Devices Finder lists over Wi‑Fi («Показывать этот iPhone при подключении к Wi‑Fi»): it keeps
    /// a token to wake each one up, so they're in its sidebar even while asleep.
    nonisolated private static var finderWiFiDevices: [String] {
        CFPreferencesAppSynchronize("com.apple.AMPDevicesAgent" as CFString)
        let tokens = CFPreferencesCopyAppValue("MobileDeviceWakeupTokens" as CFString, "com.apple.AMPDevicesAgent" as CFString)
        return ((tokens as? [String: Any])?.keys).map { Array($0).sorted() } ?? []
    }

    /// A device as this Mac remembers it: the model from the devices Finder has seen
    /// (com.apple.iPod), the name WinEx saw last, or the model's name.
    nonisolated private static func rememberedDevice(_ udid: String, names: [String: String]) -> Device? {
        CFPreferencesAppSynchronize("com.apple.iPod" as CFString)
        let seen = CFPreferencesCopyAppValue("Devices" as CFString, "com.apple.iPod" as CFString) as? [String: Any]
        // Keyed by the UDID's part after the dash
        let key = udid.split(separator: "-").last.map(String.init) ?? udid
        let info = (seen?[key] ?? seen?[udid]) as? [String: Any]
        let productType = info?["Product Type"] as? String ?? ""
        guard info != nil || names[udid] != nil else { return nil }
        // The newer of Finder's and WinEx's (a device isn't put back to an older one)
        let version = [info?["Firmware Version String"] as? String, knownVersions[udid]].compactMap { $0 }
            .max { $0.compare($1, options: .numeric) == .orderedAscending } ?? ""
        var device = Device(udid: udid, name: "", productType: productType, version: version,
                            deviceClass: info?["Device Class"] as? String ?? "iPhone", wifi: true)
        device.name = names[udid] ?? device.modelName
        device.away = true
        device.remembered = true
        return device
    }

    /// The usbmuxd entry for a device (to connect to it).
    nonisolated static func link(_ udid: String) throws -> MobileDeviceLink.Device {
        guard let device = try MobileDeviceLink.devices().first(where: { $0.udid == udid }) else {
            throw MobileDeviceLink.Failure(L("Устройство не на связи. Разблокируйте его или подключите кабелем."))
        }
        return device
    }

    // MARK: - Details

    struct Details {
        var name: String?
        var version: String?
        /// As Finder counts it: the data and system parts (not the chips' size).
        var capacity: Int64?
        var free: Int64?
        var battery: Int?
        var charging: Bool?
        var serial: String?
        var phoneNumber: String?
        var build: String?
    }

    /// What needs a session (capacity, battery…); on the devices queue.
    nonisolated static func details(_ udid: String) throws -> Details {
        let lockdown = try MobileDeviceLink.Lockdown(link(udid))
        try lockdown.startSession()
        var details = Details()
        details.name = (try? lockdown.value("DeviceName")) as? String
        details.version = (try? lockdown.value("ProductVersion")) as? String
        let usage = (try? lockdown.value(domain: "com.apple.disk_usage")) as? [String: Any] ?? [:]
        if let data = usage["TotalDataCapacity"] as? Int64 {
            details.capacity = data + (usage["TotalSystemCapacity"] as? Int64 ?? 0)
        } else {
            details.capacity = usage["TotalDiskCapacity"] as? Int64
        }
        details.free = usage["AmountDataAvailable"] as? Int64
        details.battery = (try? lockdown.value("BatteryCurrentCapacity", domain: "com.apple.mobile.battery")) as? Int
        details.charging = (try? lockdown.value("BatteryIsCharging", domain: "com.apple.mobile.battery")) as? Bool
        details.serial = (try? lockdown.value("SerialNumber")) as? String
        details.phoneNumber = (try? lockdown.value("PhoneNumber")) as? String
        details.build = (try? lockdown.value("BuildVersion")) as? String
        return details
    }

    /// What the device's page read just now (name, version): the list and the sidebar follow.
    func learnDetails(_ details: Details, for udid: String) {
        guard let index = devices.firstIndex(where: { $0.udid == udid }), !devices[index].remembered else { return }
        var device = devices[index]
        if let name = details.name, !name.isEmpty { device.name = name }
        if let version = details.version, !version.isEmpty { device.version = version }
        guard device != devices[index] else { return }
        devices[index] = device
        var names = Self.knownNames, versions = Self.knownVersions
        names[udid] = device.name
        versions[udid] = device.version
        AppDefaults.store.set(names, forKey: Self.namesKey)
        AppDefaults.store.set(versions, forKey: Self.versionsKey)
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - Open in Finder

    /// Finder's page of the device (backups, updates, syncing): a Finder window, the device
    /// clicked in its sidebar when WinEx may already use Accessibility (otherwise it's one click there).
    static func openInFinder(_ device: Device) {
        // Without Accessibility Finder only opens; say why it's asked for before the system does
        if !AXIsProcessTrusted() {
            let alert = NSAlert()
            alert.messageText = L("Открыть «%@» прямо в Finder?", device.name)
            alert.informativeText = L("Чтобы Finder сразу показывал страницу этого устройства, WinEx должен выбрать его в боковой панели Finder. Для этого нужно разрешение «Универсальный доступ» в Системных настройках. Без него откроется обычное окно Finder.")
            alert.addButton(withTitle: L("Открыть настройки"))
            alert.addButton(withTitle: L("Просто открыть Finder"))
            alert.addButton(withTitle: L("Отменить"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // Lists WinEx in Settings ▸ Универсальный доступ and opens it there
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([FileManager.default.homeDirectoryForCurrentUser], withApplicationAt: finder, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                guard AXIsProcessTrusted() else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selectInFinderSidebar(device, attempts: 8) }
            }
        }
    }

    /// Selects the device in the sidebar of Finder's front window (the outline's selected rows:
    /// selecting the row alone doesn't open its page). A device WinEx knows only by its model
    /// (asleep since before WinEx saw it) is the one device row with a name WinEx doesn't know;
    /// its name is learned from there.
    private static func selectInFinderSidebar(_ device: Device, attempts: Int) {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        var window: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        if let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            let rows = deviceRows(in: unsafeBitCast(window, to: AXUIElement.self), depth: 0)
            var target = rows.first { $0.name == device.name }
            if target == nil, device.remembered, knownNames[device.udid] == nil {
                let known = Set(shared.devices.map(\.name))
                let unknown = rows.filter { !known.contains($0.name) }
                if unknown.count == 1, let only = unknown.first {
                    target = only
                    shared.learnName(only.name, for: device.udid)
                }
            }
            if let target {
                var parent: CFTypeRef?
                AXUIElementCopyAttributeValue(target.row, kAXParentAttribute as CFString, &parent)
                if let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() {
                    AXUIElementSetAttributeValue(unsafeBitCast(parent, to: AXUIElement.self), kAXSelectedRowsAttribute as CFString, [target.row] as CFArray)
                }
                return
            }
        }
        guard attempts > 1 else { return log.info("Finder: no sidebar row «\(device.name, privacy: .public)»") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { selectInFinderSidebar(device, attempts: attempts - 1) }
    }

    /// Devices WinEx knows only by their model (asleep since before it saw them) take their names
    /// from the sidebar of an open Finder window, when WinEx may read it (Accessibility): the one
    /// device row there with a name WinEx doesn't know is theirs (only when there's exactly one).
    func learnNamesFromFinder() {
        let nameless = devices.filter { $0.remembered && Self.knownNames[$0.udid] == nil }
        guard nameless.count == 1, let device = nameless.first, AXIsProcessTrusted(),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        let windows = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let known = Set(devices.map(\.name))
        for window in windows {
            let unknown = Self.deviceRows(in: window, depth: 0).filter { !known.contains($0.name) }
            if unknown.count == 1, let only = unknown.first {
                Self.log.info("\(device.udid, privacy: .public) is «\(only.name, privacy: .public)» in Finder")
                return learnName(only.name, for: device.udid)
            }
        }
    }

    /// A name found in Finder's sidebar for a device WinEx knew only by its model.
    func learnName(_ name: String, for udid: String) {
        var names = Self.knownNames
        names[udid] = name
        AppDefaults.store.set(names, forKey: Self.namesKey)
        guard let index = devices.firstIndex(where: { $0.udid == udid }) else { return }
        devices[index].name = name
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return value
    }

    /// The sidebar's rows of iPhones, iPads and iPods: their text and the row.
    private static func deviceRows(in element: AXUIElement, depth: Int) -> [(name: String, row: AXUIElement)] {
        guard depth < 12 else { return [] }
        if attribute(element, kAXRoleAttribute) as? String == kAXRowRole {
            var texts: [String] = []
            var isDevice = false
            func visit(_ child: AXUIElement, _ level: Int) {
                guard level < 4 else { return }
                let role = attribute(child, kAXRoleAttribute) as? String
                if role == kAXStaticTextRole, let text = attribute(child, kAXValueAttribute) as? String { texts.append(text) }
                if role == kAXImageRole, let text = attribute(child, kAXDescriptionAttribute) as? String,
                   ["iPhone", "iPad", "iPod"].contains(where: text.contains) { isDevice = true }
                for next in attribute(child, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(next, level + 1) }
            }
            visit(element, 0)
            return isDevice ? texts.first.map { [($0, element)] } ?? [] : []
        }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap { deviceRows(in: $0, depth: depth + 1) }
    }
}

// MARK: - Scenarios

extension MobileDevices {
    nonisolated static func debugDiskUsage(_ udid: String) throws -> String {
        let lockdown = try MobileDeviceLink.Lockdown(link(udid))
        try lockdown.startSession()
        let usage = try lockdown.value(domain: "com.apple.disk_usage") as? [String: Any] ?? [:]
        return usage.keys.sorted().map { "\($0)=\(usage[$0] ?? "")" }.joined(separator: " ")
    }
}
