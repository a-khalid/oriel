import Foundation

/// The CPU architecture an installation ISO boots on, read from its UEFI boot image.
public enum BootArchitecture: Equatable, Sendable {
    case arm64
    case x86_64
    /// Not an El Torito ISO, no UEFI boot entry, or no recognizable bootloader. Treated as bootable.
    case unknown

    /// Whether this Mac can boot the media. Only a positive x86-64 match is rejected.
    public var isBootable: Bool { self != .x86_64 }

    private static let sectorSize: UInt64 = 2048
    private static let efiPlatformID: UInt8 = 0xEF
    private static let maxBootImageSize = 64 << 20

    /// Reads the El Torito boot catalog, finds the UEFI boot image (a FAT volume holding
    /// `EFI/BOOT/BOOT*.EFI`) and checks the machine type of the PE files inside it.
    public static func detect(isoAt url: URL) -> BootArchitecture {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        return detect(reading: { offset, length in
            try? handle.seek(toOffset: offset)
            return (try? handle.read(upToCount: length)) ?? Data()
        })
    }

    static func detect(reading read: (UInt64, Int) -> Data) -> BootArchitecture {
        // Sector 17 holds the boot record volume descriptor, which points to the boot catalog.
        let record = read(17 * sectorSize, Int(sectorSize))
        guard record.count == Int(sectorSize), record[0] == 0,
              record.subdata(in: 1..<6) == Data("CD001".utf8),
              record.subdata(in: 7..<30) == Data("EL TORITO SPECIFICATION".utf8)
        else { return .unknown }

        let catalog = read(UInt64(record.uint32(at: 0x47)) * sectorSize, Int(sectorSize))
        guard let imageSector = efiImageSector(in: catalog) else { return .unknown }

        // The catalog's sector count is unreliable (Windows ISOs say 1), so size the image
        // from its own FAT boot sector instead.
        let imageOffset = UInt64(imageSector) * sectorSize
        let bootSector = read(imageOffset, 512)
        guard bootSector.count == 512, bootSector[510] == 0x55, bootSector[511] == 0xAA else { return .unknown }
        let bytesPerSector = Int(bootSector.uint16(at: 11))
        let totalSectors = bootSector.uint16(at: 19) != 0 ? Int(bootSector.uint16(at: 19)) : Int(bootSector.uint32(at: 32))
        let imageSize = bytesPerSector * totalSectors
        guard imageSize > 0, imageSize <= maxBootImageSize else { return .unknown }

        return architecture(ofPEFilesIn: read(imageOffset, imageSize))
    }

    /// The load sector of the first boot entry for the UEFI platform, from either the
    /// validation entry (default entry) or a section header.
    private static func efiImageSector(in catalog: Data) -> UInt32? {
        guard catalog.count >= 64, catalog[0] == 0x01 else { return nil }
        var platform = catalog[1]
        for offset in stride(from: 32, to: catalog.count - 31, by: 32) {
            switch catalog[offset] {
            case 0x88 where platform == efiPlatformID: return catalog.uint32(at: offset + 8)
            case 0x90, 0x91: platform = catalog[offset + 1]
            default: continue
            }
        }
        return nil
    }

    private static func architecture(ofPEFilesIn image: Data) -> BootArchitecture {
        let signature = Data("PE\0\0".utf8)
        var foundX86 = false
        var searchStart = image.startIndex
        while let range = image.range(of: signature, in: searchStart..<image.endIndex) {
            if range.upperBound + 2 <= image.endIndex {
                switch image.uint16(at: range.upperBound - image.startIndex) {
                case 0xAA64: return .arm64
                case 0x8664, 0x014C: foundX86 = true
                default: break
                }
            }
            searchStart = range.lowerBound + 1
        }
        return foundX86 ? .x86_64 : .unknown
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }
}
