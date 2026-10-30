import Foundation

/// Everything the user can configure about a machine. Persisted as `config.json` inside the bundle.
public struct VMSpec: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var guestOS: GuestOS
    public var createdAt: Date

    public var cpuCount: Int
    public var memorySize: UInt64
    public var diskSize: UInt64
    public var display: DisplaySpec

    /// ISO/IMG the guest installs from. Attached as a USB drive while `bootFromInstallMedia` is on.
    public var installMediaPath: String?
    public var bootFromInstallMedia: Bool
    /// Extra read-only media attached alongside the installer (unattend disk, VirtIO drivers).
    public var extraMediaPaths: [String]

    public var sharedFolders: [SharedFolder]
    public var audioEnabled: Bool
    /// Clipboard sync through the SPICE agent channel (needs spice-vdagent in the guest).
    public var clipboardSharing: Bool

    public init(
        name: String,
        guestOS: GuestOS,
        cpuCount: Int,
        memorySize: UInt64,
        diskSize: UInt64,
        display: DisplaySpec = .default
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = UUID()
        self.name = name
        self.guestOS = guestOS
        self.createdAt = .nowToTheSecond
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskSize = diskSize
        self.display = display
        self.installMediaPath = nil
        self.bootFromInstallMedia = false
        self.extraMediaPaths = []
        self.sharedFolders = []
        self.audioEnabled = true
        self.clipboardSharing = guestOS != .macOS
    }
}

public struct DisplaySpec: Codable, Sendable, Hashable {
    public var widthInPixels: Int
    public var heightInPixels: Int
    public var pixelsPerInch: Int

    public init(widthInPixels: Int, heightInPixels: Int, pixelsPerInch: Int) {
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        self.pixelsPerInch = pixelsPerInch
    }

    public static let `default` = DisplaySpec(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)
}

public struct SharedFolder: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var path: String
    public var readOnly: Bool

    public init(path: String, readOnly: Bool = false) {
        self.id = UUID()
        self.path = path
        self.readOnly = readOnly
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
}

extension Date {
    /// `config.json` stores ISO 8601 dates, which drop sub-second precision; match that so a
    /// spec compares equal to itself after a save and load.
    static var nowToTheSecond: Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }
}
