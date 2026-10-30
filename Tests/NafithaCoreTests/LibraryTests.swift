import Foundation
@testable import NafithaCore
import Testing
import Virtualization

struct LibraryTests {
    private func makeLibrary() throws -> VMLibrary {
        let root = FileManager.default.temporaryDirectory.appending(path: "nafitha-tests-\(UUID().uuidString)")
        let library = VMLibrary(rootURL: root)
        try library.ensureExists()
        return library
    }

    private func linuxSpec(name: String = "Ubuntu") -> VMSpec {
        VMSpec(name: name, guestOS: .linux, cpuCount: 2, memorySize: 4 * .gibibyte, diskSize: 8 * .gibibyte)
    }

    @Test func specRoundTripsThroughJSON() throws {
        var spec = linuxSpec()
        spec.sharedFolders = [SharedFolder(path: "/tmp", readOnly: true)]
        let data = try JSONEncoder.nafitha.encode(spec)
        #expect(try JSONDecoder.nafitha.decode(VMSpec.self, from: data) == spec)
    }

    @Test func createsSparseDiskAndEFIFiles() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.rootURL) }

        let bundle = try library.create(spec: linuxSpec())
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: bundle.nvramURL.path))
        #expect(fm.fileExists(atPath: bundle.machineIdentifierURL.path))
        #expect(try DiskImage.size(of: bundle.diskURL) == 8 * .gibibyte)
        #expect(DiskImage.allocatedSize(of: bundle.diskURL) < 16 * .mebibyte)
        #expect(try VMBundle.load(from: bundle.url).spec == bundle.spec)
    }

    @Test func picksUniqueBundleNames() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.rootURL) }

        let first = try library.create(spec: linuxSpec(name: "Dev/Box"))
        let second = try library.create(spec: linuxSpec(name: "Dev/Box"))
        #expect(first.url.lastPathComponent == "Dev-Box.nafitha")
        #expect(second.url.lastPathComponent == "Dev-Box 2.nafitha")
        #expect(library.loadAll().count == 2)
    }

    @Test func duplicateGetsNewIdentity() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.rootURL) }

        let original = try library.create(spec: linuxSpec())
        let copy = try library.duplicate(original, name: "Ubuntu Copy")
        #expect(copy.id != original.id)
        #expect(copy.spec.name == "Ubuntu Copy")
        #expect(try Data(contentsOf: copy.machineIdentifierURL) != Data(contentsOf: original.machineIdentifierURL))
    }

    @Test func diskOnlyGrows() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.rootURL) }

        let bundle = try library.create(spec: linuxSpec())
        try DiskImage.grow(at: bundle.diskURL, to: 4 * .gibibyte)
        #expect(try DiskImage.size(of: bundle.diskURL) == 8 * .gibibyte)
        try DiskImage.grow(at: bundle.diskURL, to: 16 * .gibibyte)
        #expect(try DiskImage.size(of: bundle.diskURL) == 16 * .gibibyte)
    }

    @Test func memoryIsClampedToWholeMebibytes() {
        let size = HostResources.clamp(UInt64(5 * Double(UInt64.gibibyte) + 1234))
        #expect(size % .mebibyte == 0)
        #expect(HostResources.allowedMemorySize.contains(size))
    }

    @Test func linuxConfigurationHasInstallerAndSharing() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.rootURL) }

        var spec = linuxSpec()
        let iso = library.rootURL.appending(path: "installer.iso")
        try DiskImage.createSparse(at: iso, size: 4 * .mebibyte)
        spec.installMediaPath = iso.path
        spec.bootFromInstallMedia = true
        spec.sharedFolders = [SharedFolder(path: library.rootURL.path)]
        let bundle = try library.create(spec: spec)

        let configuration = try ConfigurationBuilder.build(for: bundle)
        #expect(configuration.storageDevices.count == 2)
        #expect(configuration.directorySharingDevices.count == 1)
    }

    @Test func windowsUsesNVMe() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.rootURL) }

        let spec = VMSpec(name: "Win", guestOS: .windows, cpuCount: 4, memorySize: 4 * .gibibyte, diskSize: 64 * .gibibyte)
        let bundle = try library.create(spec: spec)
        let configuration = try ConfigurationBuilder.build(for: bundle)
        #expect(configuration.storageDevices.first is VZNVMExpressControllerDeviceConfiguration)
    }

    @Test func missingInstallMediaIsReported() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.rootURL) }

        var spec = linuxSpec()
        spec.installMediaPath = "/nonexistent/installer.iso"
        spec.bootFromInstallMedia = true
        let bundle = try library.create(spec: spec)
        #expect(throws: NafithaError.installMediaMissing("/nonexistent/installer.iso")) {
            try ConfigurationBuilder.build(for: bundle)
        }
    }
}
