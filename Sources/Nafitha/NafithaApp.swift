import AppKit
import SwiftUI

@main
struct NafithaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Nafitha", id: "library") {
            LibraryView()
                .environment(appDelegate.model)
                .frame(minWidth: 780, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") { appDelegate.model.isShowingWizard = true }
                    .keyboardShortcut("n")
            }
        }

        WindowGroup(id: MachineWindow.id, for: UUID.self) { $machineID in
            if let machineID {
                MachineWindow(machineID: machineID)
                    .environment(appDelegate.model)
            }
        }
        .defaultSize(width: 1280, height: 820)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// Machines keep running when their window closes, so closing the last window must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasActiveMachines else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = String(localized: "Virtual machines are still running")
        alert.informativeText = String(localized: "Nafitha will suspend them so they resume where they left off. Machines that cannot be suspended will be shut down.")
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
