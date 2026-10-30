import OrielCore
import SwiftUI
import Virtualization

struct MachineWindow: View {
    static let id = "machine"

    @Environment(AppModel.self) private var model
    let machineID: UUID

    var body: some View {
        if let bundle = model.bundle(id: machineID) {
            MachineScreen(session: model.session(for: bundle), hasSavedState: bundle.hasSavedState)
                .navigationTitle(bundle.spec.name)
        } else {
            ContentUnavailableView("This virtual machine no longer exists", systemImage: "questionmark.square.dashed")
        }
    }
}

private struct MachineScreen: View {
    let session: VMSession
    let hasSavedState: Bool

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            if let vm = session.virtualMachine {
                VirtualMachineDisplay(virtualMachine: vm)
            }
            overlay
        }
        .toolbar { controls }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { session.lastError != nil }, set: { if !$0 { session.lastError = nil } }),
            presenting: session.lastError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    /// Pure black while the guest draws; a soft glow behind the controls while it is off.
    @ViewBuilder
    private var backdrop: some View {
        if session.virtualMachine == nil {
            RadialGradient(
                colors: [Color(red: 0.13, green: 0.15, blue: 0.24), .black],
                center: .center, startRadius: 0, endRadius: 520
            )
        } else {
            Color.black
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .stopped, .failed:
            VStack(spacing: 0) {
                GuestOSBadge(guestOS: session.bundle.spec.guestOS, size: 72)
                    .padding(.bottom, 18)
                Text(session.bundle.spec.name)
                    .font(.oriel(.title1, weight: .semibold))
                    .foregroundStyle(.white)
                Group {
                    if case .failed(let message) = session.state {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        StateLabel(state: session.state, hasSavedState: hasSavedState)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .font(.oriel(.title3))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.top, 4)
                .padding(.bottom, 24)
                Button {
                    Task { await session.start() }
                } label: {
                    Label(hasSavedState ? LocalizedStringKey("Resume") : "Start", systemImage: "play.fill")
                        .padding(.horizontal, 12)
                }
                .controlSize(.extraLarge)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(32)
        case .starting, .suspending, .stopping:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                StateLabel(state: session.state, hasSavedState: hasSavedState)
                    .font(.oriel(.title3))
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .paused:
            Button {
                Task { await session.resume() }
            } label: {
                Label("Paused — Click to Resume", systemImage: "pause.circle")
                    .font(.oriel(.title3))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: .capsule)
        case .running:
            EmptyView()
        }
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItemGroup {
            if session.state == .paused {
                Button { Task { await session.resume() } } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .help("Resume")
            } else {
                Button { Task { await session.pause() } } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .help("Pause")
                .disabled(session.state != .running)
            }

            Button { Task { await session.suspend() } } label: {
                Label("Suspend", systemImage: "moon.fill")
            }
            .help("Save the machine's state and stop it. Starting it again picks up where you left off.")
            .disabled(!session.canSuspend)

            Button { session.requestShutdown() } label: {
                Label("Shut Down", systemImage: "power")
            }
            .help("Ask the guest system to shut down")
            .disabled(session.state != .running)

            Menu {
                Button("Force Stop", role: .destructive) { Task { await session.forceStop() } }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(!session.state.isActive)
        }
    }
}

/// Hosts Apple's `VZVirtualMachineView`, which renders the guest and forwards keyboard and mouse.
private struct VirtualMachineDisplay: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = virtualMachine
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== virtualMachine {
            view.virtualMachine = virtualMachine
        }
    }
}
