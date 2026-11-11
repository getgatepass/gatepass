import Foundation

struct Account: Equatable {
    let email: String
    let firstName: String

    var initials: String {
        let source = firstName.isEmpty ? email : firstName
        return String(source.prefix(1)).uppercased()
    }
}

struct Device: Identifiable, Equatable, Hashable {
    let udid: String
    let name: String
    let connection: String   // "usb" | "wifi"
    let productType: String?
    let osVersion: String?

    var id: String { udid }
    var isAppleTV: Bool { productType?.hasPrefix("AppleTV") ?? false }
    var isIPad: Bool { productType?.hasPrefix("iPad") ?? false }
    var isWireless: Bool { connection == "wifi" }

    var symbol: String {
        if isAppleTV { return "appletv.fill" }
        if isIPad { return "ipad" }
        return "iphone"
    }

    var subtitle: String {
        let os = isAppleTV ? "tvOS" : (isIPad ? "iPadOS" : "iOS")
        let version = osVersion.map { "\(os) \($0)" } ?? os
        return "\(version) · \(isWireless ? "Wi-Fi" : "USB")"
    }

    init?(json: JSON) {
        guard let udid = json["udid"] as? String else { return nil }
        self.udid = udid
        self.name = (json["name"] as? String) ?? "Unknown device"
        self.connection = (json["connection"] as? String) ?? "usb"
        self.productType = json["productType"] as? String
        self.osVersion = json["osVersion"] as? String
    }
}

struct TrackedApp: Identifiable, Equatable {
    let deviceUDID: String
    let deviceName: String
    let name: String
    let bundleId: String
    let expiresAt: Date?
    let refreshAt: Date?
    let due: Bool

    var id: String { deviceUDID + "/" + bundleId }

    var daysLeft: Int? {
        guard let expiresAt else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: .now, to: expiresAt).day ?? 0)
    }

    var isExpired: Bool { (expiresAt ?? .distantFuture) < .now }
}

struct IPAFile: Identifiable, Equatable, Hashable {
    let url: URL
    var name: String
    var bundleId: String?
    var version: String?
    var iconURL: URL?

    var id: String { url.path }

    var fileSize: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum DateParsing {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()

    static func parse(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }
}

struct Quota: Equatable {
    struct DeviceSlots: Equatable { let udid: String; let name: String; let active: Int; let limit: Int }
    let available: Int
    let max: Int
    let exact: Bool
    let devices: [DeviceSlots]

    init?(json: JSON) {
        guard let ids = json["appIds"] as? JSON else { return nil }
        available = ids["available"] as? Int ?? 0
        max = ids["max"] as? Int ?? 10
        exact = ids["exact"] as? Bool ?? false
        devices = ((json["devices"] as? [JSON]) ?? []).map {
            DeviceSlots(udid: $0["udid"] as? String ?? "", name: $0["name"] as? String ?? "",
                        active: $0["active"] as? Int ?? 0, limit: $0["limit"] as? Int ?? 3)
        }
    }
}
