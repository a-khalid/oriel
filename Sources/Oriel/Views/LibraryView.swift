import AppKit
import OrielCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
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
                        .padding()
                        .multilineTextAlignment(.center)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        model.startNewMachine()
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
        // An empty sidebar only repeats what the welcome screen says, so it stays out of the way until there is a machine.
        .onAppear { columns = model.machines.isEmpty ? .detailOnly : .all }
        .onChange(of: model.machines.isEmpty) { _, isEmpty in
            withAnimation { columns = isEmpty ? .detailOnly : .all }
        }
        .sheet(isPresented: $model.isShowingWizard) {
            NewMachineWizard()
                .font(.oriel(.body))
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
            GuestOSBadge(guestOS: bundle.spec.guestOS, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.spec.name)
                    .lineLimit(1)
                StatusBadge(state: state, hasSavedState: bundle.hasSavedState)
                    .font(.oriel(.caption1))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)
                Text("Welcome to Oriel")
                    .font(.oriel(.largeTitle, weight: .bold))
                Text("Every system, one window.")
                    .font(.oriel(.title3))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                Text("Choose a system to get started")
                    .font(.oriel(.headline))
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ForEach(GuestOS.allCases) { os in
                        GuestChoice(guestOS: os) { model.startNewMachine(os) }
                    }
                }
                // Cards share the tallest one's height instead of stretching to fill the window.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640)
            }

            Text("Free and open source. Runs on Apple’s Virtualization framework.")
                .font(.oriel(.footnote))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One guest family on the welcome screen. Picking it opens the wizard with that system already chosen.
private struct GuestChoice: View {
    let guestOS: GuestOS
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                GuestOSBadge(guestOS: guestOS, size: 52)
                    .padding(.bottom, 4)
                Text(guestOS.displayName)
                    .font(.oriel(.headline))
                Text(summary)
                    .font(.oriel(.callout))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .buttonStyle(ChoiceCardStyle())
        .accessibilityHint(Text("Creates a new \(guestOS.displayName) virtual machine"))
    }

    private var summary: LocalizedStringKey {
        switch guestOS {
        case .macOS: "Downloaded and installed for you"
        case .windows: "Windows 11 for ARM, set up hands-free"
        case .linux: "Any ARM64 distribution"
        }
    }
}
