import OrielCore
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
    @State private var diskSize: UInt64 = 64 * .gibibyte

    @State private var macSource = MacSource.latest
    @State private var restoreImageURL: URL?
    @State private var installMediaURL: URL?
    @State private var installMediaArchitecture = BootArchitecture.unknown
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
        .onAppear {
            if let preselected = model.wizardGuestOS { select(preselected) }
        }
    }

    // MARK: Steps

    private var chooseOSStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What would you like to run?")
                    .font(.oriel(.title2, weight: .bold))
                Text("You can change processors, memory and sharing later.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ForEach(GuestOS.allCases) { os in
                    OSChoiceRow(guestOS: os, description: description(of: os)) { select(os) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
    }

    private var configureStep: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    GuestOSBadge(guestOS: guestOS, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New \(guestOS.displayName) Virtual Machine")
                            .font(.oriel(.headline))
                        Text(description(of: guestOS))
                            .font(.oriel(.callout))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                TextField("Name", text: $name)
            }

            Section("Resources") {
                CountStepper(title: "Processors", value: $cpuCount, range: HostResources.allowedCPUCount)
                SizeSlider(title: "Memory", size: $memorySize, range: HostResources.allowedMemorySize)
                SizeSlider(title: "Disk size", size: $diskSize, range: guestOS.minimumDiskSize...(512 * .gibibyte), step: 8)
                Text("The disk only takes up the space the guest actually uses.")
                    .font(.oriel(.caption1))
                    .foregroundStyle(.secondary)
            }

            switch guestOS {
            case .macOS: macOSSection
            case .windows: windowsSections
            case .linux: linuxSection
            }
        }
        .formStyle(.grouped)
        .task(id: installMediaURL) {
            installMediaArchitecture = .unknown
            guard let url = installMediaURL else { return }
            installMediaArchitecture = await Task.detached { BootArchitecture.detect(isoAt: url) }.value
        }
    }

    @ViewBuilder
    private var installMediaWarning: some View {
        if !installMediaArchitecture.isBootable {
            Label("This ISO is for Intel and AMD (x64) PCs. This Mac can only start ARM64 systems: choose the ARM64 version.", systemImage: "exclamationmark.triangle.fill")
                .font(.oriel(.callout))
                .foregroundStyle(.red)
        }
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
                    .font(.oriel(.caption1))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var windowsSections: some View {
        Section {
            Label("Windows does not start on Apple’s Virtualization framework yet: its boot manager stops at a black screen before setup begins. Create a Windows machine only to experiment.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }

        Section("Installation") {
            FileRow(title: "Windows 11 ARM64 ISO", url: installMediaURL) { installMediaURL = FilePicker.chooseDiskImage() }
            installMediaWarning
            Link("Download Windows 11 for ARM from Microsoft", destination: URL(string: "https://www.microsoft.com/software-download/windows11arm64")!)
                .font(.oriel(.callout))
            FileRow(title: "VirtIO drivers ISO (optional)", url: virtIODriversURL) { virtIODriversURL = FilePicker.chooseDiskImage() }
            Link("Download virtio-win drivers (needed for networking)", destination: URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!)
                .font(.oriel(.callout))
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
                    .font(.oriel(.caption1))
                    .foregroundStyle(.secondary)
            }
            Text("When the screen says “Press any key to boot from CD or DVD”, click inside the window and press a key.")
                .font(.oriel(.caption1))
                .foregroundStyle(.secondary)
        }
    }

    private var linuxSection: some View {
        Section("Installation") {
            FileRow(title: "Linux ARM64 ISO", url: installMediaURL) { installMediaURL = FilePicker.chooseDiskImage() }
            installMediaWarning
            Text("Ubuntu, Fedora, Debian and most other distributions publish ARM64 (aarch64) ISOs.")
                .font(.oriel(.caption1))
                .foregroundStyle(.secondary)
        }
    }

    private var creatingStep: some View {
        VStack(spacing: 18) {
            Spacer()
            GuestOSBadge(guestOS: guestOS, size: 64)
            if let error = progress.errorMessage {
                Label("The virtual machine could not be created", systemImage: "exclamationmark.triangle.fill")
                    .font(.oriel(.title3, weight: .bold))
                    .symbolRenderingMode(.multicolor)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(progress.phase)
                    .font(.oriel(.title3, weight: .bold))
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 360)
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
        diskSize = os.defaultDiskSize
        installMediaURL = nil
        step = .configure
    }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch guestOS {
        case .macOS: return macSource == .latest || restoreImageURL != nil
        case .windows: return installMediaURL != nil && installMediaArchitecture.isBootable && (!automaticSetup || !userName.trimmingCharacters(in: .whitespaces).isEmpty)
        case .linux: return installMediaURL != nil && installMediaArchitecture.isBootable
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
                    diskSize: diskSize
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

private struct ExperimentalTag: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: .capsule)
    }
}

private struct OSChoiceRow: View {
    let guestOS: GuestOS
    let description: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                GuestOSBadge(guestOS: guestOS, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(guestOS.displayName).font(.oriel(.headline))
                        if guestOS.isExperimental { ExperimentalTag() }
                    }
                    Text(description)
                        .font(.oriel(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .flipsForRightToLeftLayoutDirection(true)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ChoiceCardStyle(cornerRadius: 12))
    }
}
