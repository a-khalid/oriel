import AppKit
import NafithaCore
import Observation

@Observable
final class AppModel {
    let library = VMLibrary()
    private(set) var machines: [VMBundle] = []
    private(set) var sessions: [UUID: VMSession] = [:]
    var selection: UUID?
    var isShowingWizard = false
    var alertMessage: String?

    init() {
        reload()
    }

    var hasActiveMachines: Bool { sessions.values.contains { $0.state.isActive } }

    func reload() {
        do {
            try library.ensureExists()
        } catch {
            report(error)
        }
        machines = library.loadAll()
        if selection == nil { selection = machines.first?.id }
    }

    func bundle(id: UUID) -> VMBundle? {
        machines.first { $0.id == id }
    }

    func existingSession(id: UUID) -> VMSession? {
        sessions[id]
    }

    func session(for bundle: VMBundle) -> VMSession {
        if let session = sessions[bundle.id] { return session }
        let session = VMSession(bundle: bundle)
        sessions[bundle.id] = session
        return session
    }

    func add(_ bundle: VMBundle) {
        machines.append(bundle)
        selection = bundle.id
    }

    func save(_ bundle: VMBundle) {
        do {
            try bundle.save()
            if let index = machines.firstIndex(where: { $0.id == bundle.id }) {
                machines[index] = bundle
            }
            sessions[bundle.id]?.update(bundle: bundle)
        } catch {
            report(error)
        }
    }

    func duplicate(_ bundle: VMBundle) {
        do {
            let copy = try library.duplicate(bundle, name: String(localized: "\(bundle.spec.name) Copy"))
            add(copy)
        } catch {
            report(error)
        }
    }

    func moveToTrash(_ bundle: VMBundle) {
        guard sessions[bundle.id]?.state.isActive != true else { return }
        do {
            try library.moveToTrash(bundle)
            machines.removeAll { $0.id == bundle.id }
            sessions[bundle.id] = nil
            selection = machines.first?.id
        } catch {
            report(error)
        }
    }

    func revealInFinder(_ bundle: VMBundle) {
        NSWorkspace.shared.activateFileViewerSelecting([bundle.url])
    }

    /// Used on quit: suspend what can be suspended, shut down the rest.
    func suspendAll() async {
        for session in sessions.values where session.state.isActive {
            if session.canSuspend {
                await session.suspend()
            } else {
                await session.forceStop()
            }
        }
    }

    func report(_ error: any Error) {
        alertMessage = error.localizedDescription
    }
}
