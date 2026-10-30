import Foundation

/// Builds small read-only disks (answer files, scripts) that the guest sees as a USB drive.
public enum InstallMediaBuilder {
    /// Writes `Autounattend.xml` to the root of an ISO/UDF image. Windows Setup scans removable
    /// drives for that file name; UDF lets Windows read it from a USB (non-optical) device.
    public static func makeUnattendDisk(options: WindowsUnattendOptions, at output: URL) async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "nafitha-unattend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try WindowsUnattend.xml(for: options)
            .write(to: staging.appending(path: WindowsUnattend.fileName), atomically: true, encoding: .utf8)
        try await makeImage(from: staging, to: output, volumeName: "NAFITHA")
    }

    public static func makeImage(from directory: URL, to output: URL, volumeName: String) async throws {
        try? FileManager.default.removeItem(at: output)
        try await run("/usr/bin/hdiutil", [
            "makehybrid", "-iso", "-joliet", "-udf",
            "-default-volume-name", volumeName,
            "-o", output.path,
            directory.path,
        ])
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            throw NafithaError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent, status)
        }
    }
}
