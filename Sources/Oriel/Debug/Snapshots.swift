#if DEBUG
import AppKit
import OrielCore
import SwiftUI

/// Renders every screen to PNG files and quits, so the design can be reviewed without screen recording.
/// Run with `ORIEL_SNAPSHOTS=<folder>` set; demo machines live in a temporary library, never the user's.
enum Snapshots {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["ORIEL_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        Task {
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // The real library window too, to check what the scene itself sets up (layout direction, toolbar).
            try? await Task.sleep(for: .seconds(1.5))
            if let window = NSApp.windows.first(where: \.isVisible), let frameView = window.contentView?.superview {
                write(frameView, to: output.appending(path: "library-window.png"))
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                for (name, size, view) in scenes() {
                    await capture(view, size: size, appearance: appearance, to: output.appending(path: "\(name)-\(suffix).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func scenes() -> [(String, CGSize, AnyView)] {
        let empty = AppModel(library: VMLibrary(rootURL: temporaryLibrary()))
        let filled = AppModel(library: demoLibrary())
        let windows = AppModel(library: VMLibrary(rootURL: temporaryLibrary()))
        windows.wizardGuestOS = .windows
        let library = CGSize(width: 1040, height: 680)
        let wizard = CGSize(width: 600, height: 560)
        return [
            ("welcome", library, AnyView(LibraryView().environment(empty))),
            ("detail", library, AnyView(LibraryView().environment(filled))),
            ("wizard-choose", wizard, AnyView(NewMachineWizard().environment(empty))),
            ("wizard-windows", wizard, AnyView(NewMachineWizard().environment(windows))),
            ("settings", CGSize(width: 440, height: 160), AnyView(SettingsView())),
            ("machine", CGSize(width: 900, height: 580), AnyView(MachineWindow(machineID: filled.machines[1].id).environment(filled))),
        ]
    }

    private static func temporaryLibrary() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "oriel-snapshots-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func demoLibrary() -> VMLibrary {
        let library = VMLibrary(rootURL: temporaryLibrary())
        let specs = [
            VMSpec(name: "macOS Sequoia", guestOS: .macOS, cpuCount: 4, memorySize: 8 * .gibibyte, diskSize: 80 * .gibibyte),
            VMSpec(name: "Windows 11", guestOS: .windows, cpuCount: 6, memorySize: 8 * .gibibyte, diskSize: 64 * .gibibyte),
            VMSpec(name: "Ubuntu 24.04", guestOS: .linux, cpuCount: 2, memorySize: 4 * .gibibyte, diskSize: 32 * .gibibyte),
        ]
        for spec in specs { _ = try? library.create(spec: spec) }
        return library
    }

    private static func capture(_ view: AnyView, size: CGSize, appearance: NSAppearance.Name, to url: URL) async {
        let view = AnyView(view.font(.oriel(.body)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        window.setContentSize(size)
        window.setFrameOrigin(CGPoint(x: 80, y: 80))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.2))

        if let frameView = window.contentView?.superview { write(frameView, to: url) }
        window.orderOut(nil)
    }

    private static func write(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
