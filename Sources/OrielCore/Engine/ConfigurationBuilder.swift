import Foundation
@preconcurrency import Virtualization

/// Turns a `VMBundle` into a validated `VZVirtualMachineConfiguration`.
public enum ConfigurationBuilder {
    /// Tag Linux and Windows guests mount shared folders with (`mount -t virtiofs oriel /mnt/host`).
    public static let sharedFolderTag = "oriel"

    public static func make(for bundle: VMBundle) throws -> VZVirtualMachineConfiguration {
        let config = try build(for: bundle)
        try config.validate()
        return config
    }

    /// Assembles the device graph without validating it. Validation needs the virtualization
    /// entitlement, which the unit-test runner does not have.
    static func build(for bundle: VMBundle) throws -> VZVirtualMachineConfiguration {
        let spec = bundle.spec
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = HostResources.clamp(spec.cpuCount)
        config.memorySize = HostResources.clamp(spec.memorySize)

        switch spec.guestOS {
        case .macOS: try configureMac(config, bundle: bundle)
        case .windows, .linux: try configureEFI(config, bundle: bundle)
        }

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        if spec.audioEnabled {
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            let sound = VZVirtioSoundDeviceConfiguration()
            sound.streams = [output]
            config.audioDevices = [sound]
        }

        if let sharing = directorySharing(for: spec) {
            config.directorySharingDevices = [sharing]
        }

        if spec.clipboardSharing, spec.guestOS != .macOS {
            config.consoleDevices = [spiceClipboardConsole()]
        }

        if spec.guestOS.usesEFI {
            config.serialPorts = [try consoleLog(bundle)]
        }
        return config
    }

    // MARK: Platforms

    private static func configureMac(_ config: VZVirtualMachineConfiguration, bundle: VMBundle) throws {
        guard bundle.isMacPlatformReady else {
            throw OrielError.bundleCorrupted("missing macOS platform files")
        }
        let platform = VZMacPlatformConfiguration()
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: bundle.hardwareModelURL)) else {
            throw OrielError.bundleCorrupted("hardware-model.bin")
        }
        guard hardwareModel.isSupported else { throw OrielError.hardwareModelUnsupported }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.machineIdentifierURL)) else {
            throw OrielError.bundleCorrupted("machine-identifier.bin")
        }
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()

        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try mainDisk(bundle))]

        let display = bundle.spec.display
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: display.widthInPixels,
            heightInPixels: display.heightInPixels,
            pixelsPerInch: display.pixelsPerInch
        )]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private static func configureEFI(_ config: VZVirtualMachineConfiguration, bundle: VMBundle) throws {
        let spec = bundle.spec
        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.machineIdentifierURL)) else {
            throw OrielError.bundleCorrupted("machine-identifier.bin")
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier
        config.platform = platform

        // Open the existing store; creating it here would wipe boot entries on every launch.
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: bundle.nvramURL)
        config.bootLoader = bootLoader

        // Windows ships an NVMe driver in the box, so setup sees the disk without extra drivers.
        let disk = try mainDisk(bundle)
        var storage: [VZStorageDeviceConfiguration] = spec.guestOS == .windows
            ? [VZNVMExpressControllerDeviceConfiguration(attachment: disk)]
            : [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        if spec.bootFromInstallMedia, let installPath = spec.installMediaPath {
            let installURL = URL(fileURLWithPath: installPath)
            if !BootArchitecture.detect(isoAt: installURL).isBootable {
                throw OrielError.installMediaWrongArchitecture(installURL.lastPathComponent)
            }
            for path in [installPath] + spec.extraMediaPaths {
                storage.append(VZUSBMassStorageDeviceConfiguration(attachment: try readOnlyMedia(path)))
            }
        }
        config.storageDevices = storage

        let display = spec.display
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: display.widthInPixels,
            heightInPixels: display.heightInPixels
        )]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    // MARK: Devices

    private static func mainDisk(_ bundle: VMBundle) throws -> VZDiskImageStorageDeviceAttachment {
        try VZDiskImageStorageDeviceAttachment(
            url: bundle.diskURL,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .fsync
        )
    }

    private static func readOnlyMedia(_ path: String) throws -> VZDiskImageStorageDeviceAttachment {
        guard FileManager.default.fileExists(atPath: path) else {
            throw OrielError.installMediaMissing(path)
        }
        return try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: true)
    }

    static func directorySharing(for spec: VMSpec) -> VZVirtioFileSystemDeviceConfiguration? {
        guard !spec.sharedFolders.isEmpty else { return nil }
        var directories: [String: VZSharedDirectory] = [:]
        for folder in spec.sharedFolders {
            var name = folder.name.isEmpty ? "Shared" : folder.name
            var suffix = 2
            while directories[name] != nil {
                name = "\(folder.name) \(suffix)"
                suffix += 1
            }
            directories[name] = VZSharedDirectory(url: folder.url, readOnly: folder.readOnly)
        }
        let tag = spec.guestOS == .macOS
            ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
            : sharedFolderTag
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = VZMultipleDirectoryShare(directories: directories)
        return device
    }

    /// Guest output on /dev/hvc0 (firmware, boot loader, kernel with `console=hvc0`) goes to
    /// console.log in the bundle, truncated on every start. Useful when the screen stays black.
    private static func consoleLog(_ bundle: VMBundle) throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        guard FileManager.default.createFile(atPath: bundle.consoleLogURL.path, contents: nil) else {
            throw OrielError.cannotCreateFile(bundle.consoleLogURL.path)
        }
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: try FileHandle(forWritingTo: bundle.consoleLogURL)
        )
        return port
    }

    private static func spiceClipboardConsole() -> VZVirtioConsoleDeviceConfiguration {
        let agent = VZSpiceAgentPortAttachment()
        agent.sharesClipboard = true
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        port.attachment = agent
        let console = VZVirtioConsoleDeviceConfiguration()
        console.ports[0] = port
        return console
    }
}
