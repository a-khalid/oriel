import NafithaCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.machines) { bundle in
                    MachineRow(bundle: bundle, state: model.existingSession(id: bundle.id)?.state ?? .stopped)
                        .tag(bundle.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if model.machines.isEmpty {
                    Text("No virtual machines yet")
                        .foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        model.isShowingWizard = true
                    } label: {
                        Label("New Virtual Machine", systemImage: "plus")
                    }
                    .help("New Virtual Machine")
                }
            }
        } detail: {
            if let id = model.selection, let bundle = model.bundle(id: id) {
                MachineDetailView(bundle: bundle)
                    .id(id)
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $model.isShowingWizard) {
            NewMachineWizard()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }),
            presenting: model.alertMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}

private struct MachineRow: View {
    let bundle: VMBundle
    let state: VMSession.State

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: bundle.spec.guestOS.symbolName)
                .font(.title2)
                .frame(width: 28)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.spec.name)
                    .lineLimit(1)
                StateLabel(state: state, hasSavedState: bundle.hasSavedState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Human-readable machine state, shared by the sidebar, detail and machine windows.
struct StateLabel: View {
    let state: VMSession.State
    let hasSavedState: Bool

    var body: some View {
        switch state {
        case .stopped: hasSavedState ? Text("Suspended") : Text("Stopped")
        case .starting: Text("Starting…")
        case .running: Text("Running")
        case .paused: Text("Paused")
        case .suspending: Text("Suspending…")
        case .stopping: Text("Shutting down…")
        case .failed: Text("Error")
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to Nafitha")
                .font(.largeTitle.bold())
            Text("Run macOS, Windows and Linux side by side on your Mac — free and open source.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button {
                model.isShowingWizard = true
            } label: {
                Label("Create a Virtual Machine", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
