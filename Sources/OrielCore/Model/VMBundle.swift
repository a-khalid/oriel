import Foundation
@preconcurrency import Virtualization

/// A `.oriel` directory holding one machine: its config, disk and platform identity.
///
///     Name.oriel/
///       config.json            VMSpec
///       disk.img               sparse RAW disk
///       machine-identifier.bin generic (EFI) or Mac machine identifier, created once
///       nvram.bin              EFI variable store (EFI guests), created once
///       hardware-model.bin     Mac hardware model (macOS guests)
///       auxiliary-storage.bin  Mac auxiliary storage (macOS guests)
///       state.vzvmsave         saved machine state while suspended
///       unattend.iso           generated Windows answer file disk
///       console.log            guest serial console output (EFI guests)
public struct VMBundle: Sendable, Identifiable, Hashable {
    public static let pathExtension = "oriel"

    public let url: URL
    public var spec: VMSpec

    public var id: UUID { spec.id }

    public var configURL: URL { url.appending(path: "config.json") }
    public var diskURL: URL { url.appending(path: "disk.img") }
    public var machineIdentifierURL: URL { url.appending(path: "machine-identifier.bin") }
    public var nvramURL: URL { url.appending(path: "nvram.bin") }
    public var hardwareModelURL: URL { url.appending(path: "hardware-model.bin") }
    public var auxiliaryStorageURL: URL { url.appending(path: "auxiliary-storage.bin") }
    public var savedStateURL: URL { url.appending(path: "state.vzvmsave") }
    public var unattendMediaURL: URL { url.appending(path: "unattend.iso") }
    public var consoleLogURL: URL { url.appending(path: "console.log") }

    public var hasSavedState: Bool { FileManager.default.fileExists(atPath: savedStateURL.path) }

    /// macOS bundles are only bootable once the installer has written the platform files.
    public var isMacPlatformReady: Bool {
        let fm = FileManager.default
        return [hardwareModelURL, machineIdentifierURL, auxiliaryStorageURL].allSatisfy { fm.fileExists(atPath: $0.path) }
    }

    public static func == (lhs: VMBundle, rhs: VMBundle) -> Bool { lhs.url == rhs.url && lhs.spec == rhs.spec }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }

    // MARK: Persistence

    public static func load(from url: URL) throws -> VMBundle {
        let data = try Data(contentsOf: url.appending(path: "config.json"))
        let spec = try JSONDecoder.oriel.decode(VMSpec.self, from: data)
        return VMBundle(url: url, spec: spec)
    }

    public func save() throws {
        try JSONEncoder.oriel.encode(spec).write(to: configURL, options: .atomic)
    }

    /// Creates the directory, the sparse disk and (for EFI guests) the NVRAM and machine identifier.
    /// Mac platform files are written later by `prepareMacPlatform(hardwareModel:)`.
    public static func create(at url: URL, spec: VMSpec) throws -> VMBundle {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        let bundle = VMBundle(url: url, spec: spec)
        do {
            try bundle.save()
            try DiskImage.createSparse(at: bundle.diskURL, size: spec.diskSize)
            if spec.guestOS.usesEFI {
                _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.nvramURL, options: [])
                try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
            }
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return bundle
    }

    public func prepareMacPlatform(hardwareModel: VZMacHardwareModel) throws {
        try hardwareModel.dataRepresentation.write(to: hardwareModelURL)
        try VZMacMachineIdentifier().dataRepresentation.write(to: machineIdentifierURL)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: auxiliaryStorageURL, hardwareModel: hardwareModel, options: .allowOverwrite)
    }

    /// Gives a copied bundle its own identity so both copies can run side by side.
    public func regenerateMachineIdentifier() throws {
        let data = spec.guestOS == .macOS
            ? VZMacMachineIdentifier().dataRepresentation
            : VZGenericMachineIdentifier().dataRepresentation
        try data.write(to: machineIdentifierURL, options: .atomic)
    }

    public func discardSavedState() {
        try? FileManager.default.removeItem(at: savedStateURL)
    }
}

extension JSONEncoder {
    static var oriel: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var oriel: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
