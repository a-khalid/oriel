import Foundation
@testable import OrielCore
import Testing

struct BootArchitectureTests {
    /// Builds a minimal El Torito ISO whose UEFI boot image is a FAT volume holding one PE header.
    private func iso(machine: UInt16, efiInSection: Bool, catalogSectorCount: UInt16 = 1) -> Data {
        let sector = 2048
        var data = Data(count: sector * 24)
        func put(_ bytes: [UInt8], at offset: Int) { data.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { le16(UInt16(v & 0xFFFF)) + le16(UInt16(v >> 16)) }

        // Boot record volume descriptor pointing to the catalog in sector 19.
        put([0] + Array("CD001".utf8) + [1] + Array("EL TORITO SPECIFICATION".utf8), at: 17 * sector)
        put(le32(19), at: 17 * sector + 0x47)

        // Catalog: a BIOS default entry, then (optionally) a UEFI section, as Windows x64 ISOs do.
        let catalog = 19 * sector
        put([0x01, efiInSection ? 0x00 : 0xEF], at: catalog)
        func entry(at offset: Int, sector: UInt32) {
            put([0x88], at: offset)
            put(le16(catalogSectorCount) + le32(sector), at: offset + 6)
        }
        if efiInSection {
            entry(at: catalog + 32, sector: 21)
            put([0x91, 0xEF] + le16(1), at: catalog + 64)
            entry(at: catalog + 96, sector: 20)
        } else {
            entry(at: catalog + 32, sector: 20)
        }

        // FAT boot sector: 512-byte sectors, 16 sectors in total, then a PE header inside.
        let image = 20 * sector
        put(le16(512), at: image + 11)
        put(le16(16), at: image + 19)
        put([0x55, 0xAA], at: image + 510)
        put(Array("PE".utf8) + [0, 0] + le16(machine), at: image + 4096)
        return data
    }

    private func detect(_ data: Data) -> BootArchitecture {
        BootArchitecture.detect(reading: { offset, length in
            let start = min(Int(offset), data.count)
            return data.subdata(in: start..<min(start + length, data.count))
        })
    }

    @Test func detectsARM64() {
        #expect(detect(iso(machine: 0xAA64, efiInSection: false)) == .arm64)
    }

    @Test func detectsX64InUEFISection() {
        let result = detect(iso(machine: 0x8664, efiInSection: true))
        #expect(result == .x86_64)
        #expect(!result.isBootable)
    }

    @Test func ignoresCatalogSectorCount() {
        // Windows ISOs report 1 sector for a 1.4 MB image; the FAT header gives the real size.
        #expect(detect(iso(machine: 0x8664, efiInSection: true, catalogSectorCount: 1)) == .x86_64)
    }

    @Test func unknownMediaStaysBootable() {
        let result = detect(Data(count: 2048 * 24))
        #expect(result == .unknown)
        #expect(result.isBootable)
    }
}
