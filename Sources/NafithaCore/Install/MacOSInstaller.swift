import Foundation
@preconcurrency import Virtualization

/// Fetches, downloads and installs macOS into a fresh bundle.
@MainActor
public enum MacOSInstaller {
    public struct LatestImage: Sendable {
        public let url: URL
        public let version: String
        public let build: String
    }

    /// Asks Apple for the newest restore image this Mac can run.
    public static func latestSupportedImage() async throws -> LatestImage {
        let image = try await VZMacOSRestoreImage.latestSupported
        let version = image.operatingSystemVersion
        return LatestImage(
            url: image.url,
            version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            build: image.buildVersion
        )
    }

    /// Installs from a local `.ipsw`. Writes the platform files, raises CPU/memory to the
    /// image's minimum if needed, then runs `VZMacOSInstaller`.
    public static func install(
        into bundle: VMBundle,
        restoreImage localURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> VMBundle {
        let image = try await VZMacOSRestoreImage.image(from: localURL)
        guard let requirements = image.mostFeaturefulSupportedConfiguration,
              requirements.hardwareModel.isSupported else {
            throw NafithaError.restoreImageUnsupported
        }

        var bundle = bundle
        bundle.spec.cpuCount = max(bundle.spec.cpuCount, requirements.minimumSupportedCPUCount)
        bundle.spec.memorySize = max(bundle.spec.memorySize, requirements.minimumSupportedMemorySize)
        try bundle.save()
        try bundle.prepareMacPlatform(hardwareModel: requirements.hardwareModel)

        let vm = VZVirtualMachine(configuration: try ConfigurationBuilder.make(for: bundle))
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: localURL)
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progressObject, _ in
            let fraction = progressObject.fractionCompleted
            Task { @MainActor in progress(fraction) }
        }
        defer { observation.invalidate() }

        let installProgress = installer.progress
        try await withTaskCancellationHandler {
            try await installer.installOnMain()
        } onCancel: {
            installProgress.cancel()
        }
        return bundle
    }
}
