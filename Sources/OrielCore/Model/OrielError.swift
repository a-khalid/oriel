import Foundation

public enum OrielError: LocalizedError, Equatable {
    case cannotCreateFile(String)
    case bundleCorrupted(String)
    case hardwareModelUnsupported
    case restoreImageUnsupported
    case installMediaMissing(String)
    case installMediaWrongArchitecture(String)
    case commandFailed(String, Int32)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let path):
            String(localized: "Could not create file at \(path).")
        case .bundleCorrupted(let detail):
            String(localized: "The virtual machine files are damaged: \(detail)")
        case .hardwareModelUnsupported:
            String(localized: "This Mac cannot run the macOS version this machine was created with.")
        case .restoreImageUnsupported:
            String(localized: "This macOS restore image is not supported on this Mac.")
        case .installMediaMissing(let path):
            String(localized: "The installation media could not be found: \(path)")
        case .installMediaWrongArchitecture(let name):
            String(localized: "\(name) is for Intel and AMD (x64) PCs. This Mac can only start ARM64 systems: download the ARM64 version of the ISO.")
        case .commandFailed(let command, let status):
            String(localized: "\(command) failed with exit code \(status).")
        case .notRunning:
            String(localized: "The virtual machine is not running.")
        }
    }
}
