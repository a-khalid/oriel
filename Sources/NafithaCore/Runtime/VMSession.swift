import Foundation
import Observation
@preconcurrency import Virtualization

/// Owns one running `VZVirtualMachine`. Virtualization.framework requires every call on the
/// queue the machine was created on; we create it on the main queue, hence `@MainActor`.
@MainActor
@Observable
public final class VMSession: NSObject {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        case paused
        case suspending
        case stopping
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .starting, .running, .paused, .suspending, .stopping: true
            case .stopped, .failed: false
            }
        }
    }

    public private(set) var state: State = .stopped
    public private(set) var virtualMachine: VZVirtualMachine?
    public private(set) var bundle: VMBundle
    /// Whether this machine's device set can be saved to disk (macOS 14+, no unsupported devices).
    public private(set) var supportsSuspend = false
    /// The last operation that failed while the machine kept running. The UI shows and clears it.
    public var lastError: String?

    @ObservationIgnored private var stateObservation: NSKeyValueObservation?

    public init(bundle: VMBundle) {
        self.bundle = bundle
    }

    /// Picks up settings edited while the machine was off.
    public func update(bundle: VMBundle) {
        guard !state.isActive else { return }
        self.bundle = bundle
    }

    // MARK: Lifecycle

    /// Starts the machine, resuming from a saved state when one exists.
    public func start(inRecovery: Bool = false) async {
        guard !state.isActive else { return }
        state = .starting
        do {
            let configuration = try ConfigurationBuilder.make(for: bundle)
            supportsSuspend = (try? configuration.validateSaveRestoreSupport()) != nil
            let vm = VZVirtualMachine(configuration: configuration)
            attach(vm)

            if bundle.hasSavedState, !inRecovery, await restoreSavedState(vm) {
                return
            }

            if inRecovery, bundle.spec.guestOS == .macOS {
                let options = VZMacOSVirtualMachineStartOptions()
                options.startUpFromMacOSRecovery = true
                try await vm.startOnMain(options: options)
            } else {
                try await vm.startOnMain()
            }
            state = .running
        } catch {
            fail(error)
        }
    }

    public func pause() async {
        guard let vm = virtualMachine, vm.canPause else { return }
        do { try await vm.pauseOnMain() } catch { report(error, vm) }
    }

    public func resume() async {
        guard let vm = virtualMachine, vm.canResume else { return }
        do { try await vm.resumeOnMain() } catch { report(error, vm) }
    }

    /// Asks the guest to shut down, like pressing the power button.
    public func requestShutdown() {
        guard let vm = virtualMachine, vm.canRequestStop else { return }
        do {
            try vm.requestStop()
            state = .stopping
        } catch {
            report(error, vm)
        }
    }

    /// Pulls the plug. The guest may lose unsaved data.
    public func forceStop() async {
        guard let vm = virtualMachine, vm.canStop else { return }
        do {
            try await vm.stopOnMain()
            detach()
        } catch {
            report(error, vm)
        }
    }

    public var canSuspend: Bool {
        guard let vm = virtualMachine else { return false }
        return supportsSuspend && (vm.state == .running || vm.state == .paused)
    }

    /// Saves RAM and device state to disk, then stops. The next `start()` resumes from it.
    /// If saving fails the machine is resumed, so the user never loses a running guest.
    public func suspend() async {
        guard let vm = virtualMachine, canSuspend else { return }
        let wasRunning = vm.state == .running
        state = .suspending
        do {
            if wasRunning { try await vm.pauseOnMain() }
            try await vm.saveStateOnMain(to: bundle.savedStateURL)
        } catch {
            bundle.discardSavedState()
            supportsSuspend = false
            if wasRunning, vm.canResume { try? await vm.resumeOnMain() }
            report(error, vm, message: String(localized: "Could not suspend: \(error.localizedDescription) The machine is still running."))
            return
        }
        do {
            try await vm.stopOnMain()
            detach()
        } catch {
            report(error, vm)
        }
    }

    // MARK: Internals

    private func restoreSavedState(_ vm: VZVirtualMachine) async -> Bool {
        do {
            try await vm.restoreStateOnMain(from: bundle.savedStateURL)
            bundle.discardSavedState()
            try await vm.resumeOnMain()
            state = .running
            return true
        } catch {
            // A state saved by an older macOS or a different config cannot be restored; cold boot instead.
            bundle.discardSavedState()
            return false
        }
    }

    private func attach(_ vm: VZVirtualMachine) {
        vm.delegate = self
        virtualMachine = vm
        stateObservation = vm.observe(\.state, options: [.new]) { [weak self] vm, _ in
            let newState = vm.state
            MainActor.assumeIsolated { self?.sync(with: newState) }
        }
    }

    private func detach() {
        stateObservation?.invalidate()
        stateObservation = nil
        virtualMachine?.delegate = nil
        virtualMachine = nil
        state = .stopped
    }

    private func sync(with vmState: VZVirtualMachine.State) {
        switch vmState {
        case .running: state = .running
        case .paused: if state != .suspending { state = .paused }
        case .starting, .resuming, .restoring: state = .starting
        case .pausing, .saving: break
        case .stopping: state = .stopping
        case .stopped: if state != .suspending { detach() }
        case .error: fail(nil)
        @unknown default: break
        }
    }

    /// An operation failed but the machine is still alive: keep it attached and mirror its real state.
    private func report(_ error: any Error, _ vm: VZVirtualMachine, message: String? = nil) {
        lastError = message ?? error.localizedDescription
        if virtualMachine === vm {
            state = .running
            sync(with: vm.state)
        }
    }

    /// The machine is gone (failed to start, or stopped with an error).
    private func fail(_ error: (any Error)?) {
        stateObservation?.invalidate()
        stateObservation = nil
        virtualMachine = nil
        state = .failed(error?.localizedDescription ?? String(localized: "The virtual machine stopped unexpectedly."))
    }
}

extension VMSession: @preconcurrency VZVirtualMachineDelegate {
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        detach()
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        fail(error)
    }
}
