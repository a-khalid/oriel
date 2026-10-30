import AppKit
import SwiftUI

@main
struct OrielApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Oriel", id: "library") {
            LibraryView()
                .environment(appDelegate.model)
                .font(.oriel(.body))
                .frame(minWidth: 780, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") { appDelegate.model.startNewMachine() }
                    .keyboardShortcut("n")
            }
        }

        WindowGroup(id: MachineWindow.id, for: UUID.self) { $machineID in
            if let machineID {
                MachineWindow(machineID: machineID)
                    .environment(appDelegate.model)
                    .font(.oriel(.body))
            }
        }
        .defaultSize(width: 1280, height: 820)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        Snapshots.runIfRequested()
        #endif
    }

    /// Machines keep running when their window closes, so closing the last window must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasActiveMachines else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = String(localized: "Virtual machines are still running")
        alert.informativeText = String(localized: "Oriel will suspend them so they resume where they left off. Machines that cannot be suspended will be shut down.")
        alert.addButton(withTitle: String(localized: "Suspend and Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task {
            await model.suspendAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
