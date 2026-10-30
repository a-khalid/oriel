import Foundation

/// The guest families Oriel knows how to configure.
public enum GuestOS: String, Codable, CaseIterable, Sendable, Identifiable {
    case macOS
    case windows
    case linux

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .windows: "Windows 11"
        case .linux: "Linux"
        }
    }

    public var symbolName: String {
        switch self {
        case .macOS: "apple.logo"
        case .windows: "square.split.2x2.fill"
        case .linux: "terminal.fill"
        }
    }

    /// Windows 11 for ARM does not get past its boot manager on Virtualization.framework yet.
    public var isExperimental: Bool { self == .windows }

    /// macOS guests boot through Apple's own boot loader; everything else uses UEFI.
    public var usesEFI: Bool { self != .macOS }

    public var defaultDiskSize: UInt64 {
        switch self {
        case .macOS, .windows: 64 * .gibibyte
        case .linux: 32 * .gibibyte
        }
    }

    public var minimumDiskSize: UInt64 {
        switch self {
        case .macOS: 32 * .gibibyte
        case .windows: 40 * .gibibyte
        case .linux: 8 * .gibibyte
        }
    }
}

extension UInt64 {
    public static let mebibyte: UInt64 = 1 << 20
    public static let gibibyte: UInt64 = 1 << 30
}
