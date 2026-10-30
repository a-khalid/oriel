import NafithaCore
import SwiftUI

struct NewMachineWizard: View {
    private enum Step { case chooseOS, configure, creating }
    private enum MacSource: Hashable { case latest, file }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var step = Step.chooseOS
    @State private var guestOS = GuestOS.macOS
    @State private var name = ""
    @State private var cpuCount = 4
    @State private var memorySize: UInt64 = 8 * .gibibyte
    @State private var diskGiB = 64.0

    @State private var macSource = MacSource.latest
    @State private var restoreImageURL: URL?
    @State private var installMediaURL: URL?
    @State private var virtIODriversURL: URL?

    @State private var automaticSetup = true
    @State private var userName = NSUserName()
    @State private var password = ""
    @State private var setupLanguage = "en-US"
    @State private var edition = "Windows 11 Pro"

    @State private var progress = CreationProgress()
    @State private var creationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .chooseOS: chooseOSStep
            case .configure: configureStep
            case .creating: creatingStep
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 560)
        .interactiveDismissDisabled(step == .creating)
    }

    // MARK: Steps

    private var chooseOSStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What would you like to run?")
                .font(.title2.bold())
            ForEach(GuestOS.allCases) { os in
                Button {
                    select(os)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: os.symbolName)
                            .font(.system(size: 28))
                            .frame(width: 44)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(os.displayName).font(.headline)
                            Text(description(of: os))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(.tertiary)
                            .flipsForRightToLeftLayoutDirection(true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(24)
    }

    private var configureStep: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            }

            Section("Resources") {
                Stepper(value: $cpuCount, in: HostResources.allowedCPUCount) {
                    LabeledContent("Processors", value: "\(cpuCount)")
                }
                MemorySlider(memorySize: $memorySize)
                LabeledContent("Disk size") {
                    HStack {
                        Slider(value: $diskGiB, in: Double(guestOS.minimumDiskSize / .gibibyte)...512, step: 8)
                            .frame(minWidth: 160)
                        Text((UInt64(diskGiB) * .gibibyte).formatted(.byteCount(style: .file)))
                            .monospacedDigit()
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                Text("The disk only takes up the space the guest actually uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch guestOS {
            case .macOS: macOSSection
            case .windows: windowsSections
            case .linux: linuxSection
            }
        }
        .formStyle(.grouped)
    }

    private var macOSSection: some View {
        Section("Installation") {
            Picker("Install from", selection: $macSource) {
                Text("Latest version from Apple").tag(MacSource.latest)
                Text("A restore image file (.ipsw)").tag(MacSource.file)
            }
            .pickerStyle(.radioGroup)
            if macSource == .file {
                FileRow(title: "Restore image", url: restoreImageURL) { restoreImageURL = FilePicker.chooseRestoreImage() }
            } else {
                Text("About 15 GB will be downloaded from Apple. The download is kept so the next machine is faster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var windowsSections: some View {
        Section("Installation") {
            FileRow(title: "Windows 11 ARM64 ISO", url: installMediaURL) { installMediaURL = FilePicker.chooseDiskImage() }
            Link("Download Windows 11 for ARM from Microsoft", destination: URL(string: "https://www.microsoft.com/software-download/windows11arm64")!)
                .font(.callout)
            FileRow(title: "VirtIO drivers ISO (optional)", url: virtIODriversURL) { virtIODriversURL = FilePicker.chooseDiskImage() }
            Link("Download virtio-win drivers (needed for networking)", destination: URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!)
                .font(.callout)
        }

        Section("Automatic Setup") {
            Toggle("Set up Windows automatically", isOn: $automaticSetup)
            if automaticSetup {
                TextField("User name", text: $userName)
                SecureField("Password (optional)", text: $password)
                Picker("Language of the ISO", selection: $setupLanguage) {
                    ForEach(Self.windowsLanguages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                Picker("Edition", selection: $edition) {
                    Text(verbatim: "Windows 11 Pro").tag("Windows 11 Pro")
                    Text(verbatim: "Windows 11 Home").tag("Windows 11 Home")
                }
                Text("Erases the virtual disk, skips the TPM check (this Mac has no virtual TPM) and creates a local account. Windows still needs your own license to activate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("When the screen says “Press any key to boot from CD or DVD”, click inside the window and press a key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var linuxSection: some View {
        Section("Installation") {
            FileRow(title: "Linux ARM64 ISO", url: installMediaURL) { installMediaURL = FilePicker.chooseDiskImage() }
            Text("Ubuntu, Fedora, Debian and most other distributions publish ARM64 (aarch64) ISOs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var creatingStep: some View {
        VStack(spacing: 18) {
            Spacer()
            if let error = progress.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("The virtual machine could not be created")
                    .font(.title3.bold())
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(progress.phase)
                    .font(.title3.bold())
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            Spacer()
        }
        .padding(32)
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                creationTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            switch step {
            case .chooseOS:
                EmptyView()
            case .configure:
                Button("Back") { step = .chooseOS }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            case .creating:
                if progress.errorMessage != nil {
                    Button("Back") { step = .configure }
                }
            }
        }
        .padding(16)
    }

    // MARK: Logic

    private static let windowsLanguages = ["en-US", "en-GB", "ar-SA", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "tr-TR", "ru-RU", "zh-CN", "ja-JP", "ko-KR"]

    private func description(of os: GuestOS) -> LocalizedStringKey {
        switch os {
        case .macOS: "Downloads the latest macOS from Apple and installs it for you."
        case .windows: "Installs Windows 11 for ARM from an ISO, with optional hands-free setup."
        case .linux: "Installs any ARM64 Linux distribution from an ISO."
        }
    }

    private func select(_ os: GuestOS) {
        guestOS = os
        name = os.displayName
        cpuCount = HostResources.recommendedCPUCount(for: os)
        memorySize = HostResources.recommendedMemorySize(for: os)
        diskGiB = Double(os.defaultDiskSize / .gibibyte)
        installMediaURL = nil
        step = .configure
    }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch guestOS {
        case .macOS: return macSource == .latest || restoreImageURL != nil
        case .windows: return installMediaURL != nil && (!automaticSetup || !userName.trimmingCharacters(in: .whitespaces).isEmpty)
        case .linux: return installMediaURL != nil
        }
    }

    private func create() {
        step = .creating
        progress = CreationProgress()
        let progress = progress

        creationTask = Task {
            var created: VMBundle?
            do {
                var spec = VMSpec(
                    name: name.trimmingCharacters(in: .whitespaces),
                    guestOS: guestOS,
                    cpuCount: cpuCount,
                    memorySize: memorySize,
                    diskSize: UInt64(diskGiB) * .gibibyte
                )
                if guestOS != .macOS {
                    spec.installMediaPath = installMediaURL?.path
                    spec.bootFromInstallMedia = true
                }

                progress.update(String(localized: "Creating the virtual disk…"))
                var bundle = try model.library.create(spec: spec)
                created = bundle

                switch guestOS {
                case .macOS:
                    bundle = try await installMacOS(into: bundle, progress: progress)
                case .windows:
                    if automaticSetup {
                        progress.update(String(localized: "Preparing automatic setup…"))
                        let options = WindowsUnattendOptions(
                            userName: userName.trimmingCharacters(in: .whitespaces),
                            password: password,
                            setupLanguage: setupLanguage,
                            userLocale: Locale.current.identifier(.bcp47),
                            keyboardLayouts: Array(Set([setupLanguage, Locale.current.identifier(.bcp47)])).sorted(),
                            edition: edition,
                            installVirtIODrivers: virtIODriversURL != nil
                        )
                        try await InstallMediaBuilder.makeUnattendDisk(options: options, at: bundle.unattendMediaURL)
                        bundle.spec.extraMediaPaths.append(bundle.unattendMediaURL.path)
                    }
                    if let virtIODriversURL {
                        bundle.spec.extraMediaPaths.append(virtIODriversURL.path)
                    }
                    try bundle.save()
                case .linux:
                    break
                }

                try Task.checkCancellation()
                model.add(bundle)
                dismiss()

                let session = model.session(for: bundle)
                openWindow(id: MachineWindow.id, value: bundle.id)
                await session.start()
            } catch {
                if let created {
                    try? FileManager.default.removeItem(at: created.url)
                }
                if !Task.isCancelled {
                    progress.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func installMacOS(into bundle: VMBundle, progress: CreationProgress) async throws -> VMBundle {
        let imageURL: URL
        if macSource == .file, let restoreImageURL {
            imageURL = restoreImageURL
        } else {
            progress.update(String(localized: "Finding the latest macOS…"))
            let latest = try await MacOSInstaller.latestSupportedImage()
            progress.update(String(localized: "Downloading macOS \(latest.version)…"), fraction: 0)
            let downloader = RestoreImageDownloader { fraction in
                Task { @MainActor in progress.fraction = fraction }
            }
            imageURL = try await downloader.download(latest.url)
        }
        progress.update(String(localized: "Installing macOS…"), fraction: 0)
        return try await MacOSInstaller.install(into: bundle, restoreImage: imageURL) { fraction in
            progress.fraction = fraction
        }
    }
}

@Observable
final class CreationProgress {
    var phase = ""
    var fraction: Double?
    var errorMessage: String?

    func update(_ phase: String, fraction: Double? = nil) {
        self.phase = phase
        self.fraction = fraction
    }
}

private struct FileRow: View {
    let title: LocalizedStringKey
    let url: URL?
    let choose: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(url?.lastPathComponent ?? String(localized: "None selected"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                Button("Choose…", action: choose)
            }
        }
    }
}
