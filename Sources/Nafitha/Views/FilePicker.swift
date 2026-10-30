import AppKit
import UniformTypeIdentifiers

enum FilePicker {
    static func chooseDiskImage() -> URL? {
        choose(types: [UTType(filenameExtension: "iso"), UTType(filenameExtension: "img"), .diskImage].compactMap { $0 })
    }

    static func chooseRestoreImage() -> URL? {
        choose(types: [UTType(filenameExtension: "ipsw")].compactMap { $0 })
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func choose(types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }
}
