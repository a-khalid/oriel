import OrielCore
import SwiftUI

struct MachineDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    let bundle: VMBundle
    @State private var draft: VMSpec
    @State private var isConfirmingTrash = false

    init(bundle: VMBundle) {
        self.bundle = bundle
        _draft = State(initialValue: bundle.spec)
    }

    private var session: VMSession? { model.existingSession(id: bundle.id) }
    private var state: VMSession.State { session?.state ?? .stopped }
    private var isActive: Bool { state.isActive }

    var body: some View {
        Form {
            Section {
                header
            }

            if case .failed(let message) = state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if isActive {
                Section {
                    Label("Shut down the machine to change its settings.", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hardware") {
                CountStepper(title: "Processors", value: $draft.cpuCount, range: HostResources.allowedCPUCount)
                SizeSlider(title: "Memory", size: $draft.memorySize, range: HostResources.allowedMemorySize)
                LabeledContent("Disk") {
                    Text(diskUsage)
                }
                Picker("Display", selection: $draft.display) {
                    ForEach(DisplayPreset.all, id: \.self) { preset in
                        Text(preset.title).tag(preset.spec)
                    }
                }
            }
            .disabled(isActive)

            if draft.guestOS != .macOS {
                Section("Installation Media") {
                    Toggle("Boot from installation media", isOn: $draft.bootFromInstallMedia)
                    FileRow(title: "Image", url: draft.installMediaPath.map { URL(fileURLWithPath: $0) }) {
                        if let url = FilePicker.chooseDiskImage() {
                            draft.installMediaPath = url.path
                        }
                    }
                    Text("Turn this off after the system is installed so the machine starts straight from its disk.")
                        .font(.oriel(.caption1))
                        .foregroundStyle(.secondary)
                }
                .disabled(isActive)
            }

            Section("Sharing") {
                Toggle("Sound", isOn: $draft.audioEnabled)
                if draft.guestOS != .macOS {
                    Toggle("Shared clipboard", isOn: $draft.clipboardSharing)
                }
                ForEach(draft.sharedFolders) { folder in
                    HStack {
                        Label(folder.name, systemImage: "folder")
                        Spacer()
                        if folder.readOnly {
                            Text("Read only").foregroundStyle(.secondary)
                        }
                        Button {
                            draft.sharedFolders.removeAll { $0.id == folder.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Stop sharing \(folder.name)")
                    }
                }
                Button("Share a Folder…") {
                    if let url = FilePicker.chooseFolder() {
                        draft.sharedFolders.append(SharedFolder(path: url.path))
                    }
                }
                Text(sharingHint)
                    .font(.oriel(.caption1))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .disabled(isActive)

            Section {
                HStack {
                    Button("Show in Finder") { model.revealInFinder(bundle) }
                    Button("Duplicate") { model.duplicate(bundle) }
                        .disabled(isActive)
                    Spacer()
                    Button("Move to Trash…", role: .destructive) { isConfirmingTrash = true }
                        .disabled(isActive)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bundle.spec.name)
        .onChange(of: draft) { _, newValue in
            var updated = bundle
            updated.spec = newValue
            model.save(updated)
        }
        .confirmationDialog(
            "Move “\(bundle.spec.name)” to the Trash?",
            isPresented: $isConfirmingTrash
        ) {
            Button("Move to Trash", role: .destructive) { model.moveToTrash(bundle) }
        } message: {
            Text("Its disk and settings go to the Trash. You can restore them from there until you empty it.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            GuestOSBadge(guestOS: draft.guestOS, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                // Hidden label: inside a grouped Form the label would otherwise sit beside the field as "Name".
                TextField("Name", text: $draft.name)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.oriel(.title2, weight: .bold))
                    .disabled(isActive)
                HStack(spacing: 6) {
                    Text(draft.guestOS.displayName)
                    Text("·")
                    StatusBadge(state: state, hasSavedState: bundle.hasSavedState)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Button("Show Window") { openWindow(id: MachineWindow.id, value: bundle.id) }
                    .controlSize(.large)
            } else {
                if draft.guestOS == .macOS {
                    Button("Start in Recovery") { start(inRecovery: true) }
                        .controlSize(.large)
                        .disabled(!bundle.isMacPlatformReady)
                }
                Button {
                    start(inRecovery: false)
                } label: {
                    Label(bundle.hasSavedState ? LocalizedStringKey("Resume") : "Start", systemImage: "play.fill")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 4)
    }

    private var diskUsage: String {
        let used = DiskImage.allocatedSize(of: bundle.diskURL)
        return String(localized: "\(used.formatted(.byteCount(style: .memory))) used of \(draft.diskSize.formatted(.byteCount(style: .memory)))")
    }

    private var sharingHint: String {
        switch draft.guestOS {
        case .macOS:
            String(localized: "Shared folders appear in Finder under “My Shared Files”.")
        case .linux:
            String(localized: "Mount in Linux with: sudo mount -t virtiofs \(ConfigurationBuilder.sharedFolderTag) /mnt")
        case .windows:
            String(localized: "Windows needs the VirtIO-FS driver and WinFsp from the virtio-win package to see shared folders.")
        }
    }

    private func start(inRecovery: Bool) {
        let session = model.session(for: bundle)
        openWindow(id: MachineWindow.id, value: bundle.id)
        Task { await session.start(inRecovery: inRecovery) }
    }
}

struct DisplayPreset: Hashable {
    let spec: DisplaySpec
    var title: String { "\(spec.widthInPixels) × \(spec.heightInPixels)" }

    static let all: [DisplayPreset] = [
        DisplayPreset(spec: DisplaySpec(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 110)),
        DisplayPreset(spec: DisplaySpec(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144)),
        DisplayPreset(spec: .default),
        DisplayPreset(spec: DisplaySpec(widthInPixels: 2560, heightInPixels: 1600, pixelsPerInch: 220)),
        DisplayPreset(spec: DisplaySpec(widthInPixels: 3024, heightInPixels: 1964, pixelsPerInch: 254)),
    ]
}
