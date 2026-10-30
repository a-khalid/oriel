import Foundation

public enum DiskImage {
    /// Creates a sparse RAW image: the file reports `size` bytes but only uses what the guest writes.
    public static func createSparse(at url: URL, size: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NafithaError.cannotCreateFile(url.path)
        }
        try resize(at: url, to: size)
    }

    /// Grows a disk image. Shrinking is refused because it would cut off guest data.
    public static func grow(at url: URL, to size: UInt64) throws {
        let current = try Self.size(of: url)
        guard size > current else { return }
        try resize(at: url, to: size)
    }

    public static func size(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Bytes actually allocated on the host disk.
    public static func allocatedSize(of url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? 0)
    }

    private static func resize(at url: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }
}
