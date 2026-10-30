import Foundation

/// The folder that holds every `.oriel` bundle.
public struct VMLibrary: Sendable {
    public let rootURL: URL

    public init(rootURL: URL = VMLibrary.defaultRootURL) {
        self.rootURL = rootURL
    }

    public static var defaultRootURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Oriel", directoryHint: .isDirectory)
            .appending(path: "Virtual Machines", directoryHint: .isDirectory)
    }

    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Loads every readable bundle, oldest first. Damaged bundles are skipped, not deleted.
    public func loadAll() -> [VMBundle] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == VMBundle.pathExtension }
            .compactMap { try? VMBundle.load(from: $0) }
            .sorted { $0.spec.createdAt < $1.spec.createdAt }
    }

    public func create(spec: VMSpec) throws -> VMBundle {
        try ensureExists()
        return try VMBundle.create(at: availableURL(forName: spec.name), spec: spec)
    }

    /// Copies a stopped machine. On APFS `copyItem` clones, so the copy costs no extra space until it diverges.
    public func duplicate(_ bundle: VMBundle, name: String) throws -> VMBundle {
        let destination = availableURL(forName: name)
        try FileManager.default.copyItem(at: bundle.url, to: destination)
        var copy = try VMBundle.load(from: destination)
        copy.spec.id = UUID()
        copy.spec.name = name
        copy.spec.createdAt = .nowToTheSecond
        try copy.save()
        copy.discardSavedState()
        if FileManager.default.fileExists(atPath: copy.machineIdentifierURL.path) {
            try copy.regenerateMachineIdentifier()
        }
        return copy
    }

    /// Moves to the Trash so the user can still recover it.
    public func moveToTrash(_ bundle: VMBundle) throws {
        try FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
    }

    public func availableURL(forName name: String) -> URL {
        let base = Self.sanitize(name)
        var candidate = rootURL.appending(path: "\(base).\(VMBundle.pathExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = rootURL.appending(path: "\(base) \(counter).\(VMBundle.pathExtension)")
            counter += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Virtual Machine" : cleaned
    }
}
