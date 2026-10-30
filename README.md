# Nafitha

**Nafitha** (Arabic *نافذة*, "window") is a free, open-source app for running **macOS, Windows 11 and Linux** virtual machines on Apple silicon Macs. It is built only on Apple's `Virtualization.framework`: no kernel extensions, no QEMU, no daemons.

[العربية](README.ar.md)

## Features

| | macOS | Windows 11 ARM | Linux ARM64 |
|---|---|---|---|
| Guided install | Downloads the latest IPSW from Apple and installs it | ISO + optional hands-free setup (`Autounattend.xml`) | ISO |
| Storage | VirtIO block | NVMe (Windows has the driver built in) | VirtIO block |
| Display | Retina, resizes with the window | UEFI framebuffer (fixed resolution, no 3D) | virtio-gpu, resizes |
| Shared folders | VirtioFS, auto-mounted | VirtioFS (needs virtio-win + WinFsp) | VirtioFS (`mount -t virtiofs nafitha /mnt`) |
| Clipboard | — | SPICE agent (experimental) | SPICE agent (`spice-vdagent`) |
| Suspend / resume | ✓\* | ✓\* | ✓\* |
| Sound output | ✓ | driver dependent | ✓ |

\* On macOS 27.0.1, Virtualization.framework rejects saving any EFI machine with "permission denied", even a minimal one outside Nafitha. When a suspend fails, Nafitha keeps the machine running and shows the error.

Every machine is a self-contained `.nafitha` folder under `~/Library/Application Support/Nafitha/Virtual Machines`. **Duplicate** uses APFS clones, so a copy takes no extra space until it changes.

The interface is available in **English and Arabic** (with full right-to-left layout). It supports VoiceOver and keyboard navigation.

## Requirements

- A Mac with Apple silicon (M1 or later)
- macOS 14 Sonoma or later
- To build: Xcode 26 or later (Swift 6.2 toolchain)

## Build and run

```bash
make run
```

This compiles the Swift package, assembles `build/Nafitha.app`, signs it ad hoc with the `com.apple.security.virtualization` entitlement and opens it. Other targets:

```bash
make test           # unit tests
make lint-strings   # fail if a UI string lacks a translation
make release        # optimized build
make smoke ISO=path/to/linux-arm64.iso   # boot headlessly; pass/fail from the serial console
```

`make smoke` boots the ISO through the same code the app uses and waits for `login:` on `/dev/hvc0`. The guest kernel must log to `console=hvc0`. Every EFI machine writes that console to `console.log` in its bundle.

To sign for distribution, run `SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh release`, then notarize the result.

## Installing Windows 11

1. Download the **Windows 11 ARM64 ISO** from [Microsoft](https://www.microsoft.com/software-download/windows11arm64).
2. Optional but recommended: download [`virtio-win.iso`](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso). It provides the network driver. Nafitha installs it automatically at first logon.
3. In Nafitha, choose **New Virtual Machine → Windows 11** and keep **Set up Windows automatically** on.
4. When the window shows *Press any key to boot from CD or DVD*, click inside it and press a key.
5. After you reach the desktop, turn off **Boot from installation media** in the machine's settings.

Virtualization.framework has no virtual TPM, so automatic setup bypasses the Windows 11 TPM and Secure Boot checks. Windows still needs your own license to activate.

## Architecture

```
Sources/
  NafithaCore/            no UI; everything that touches Virtualization.framework
    Model/                VMSpec (config.json), VMBundle (on-disk layout), VMLibrary, DiskImage
    Engine/               ConfigurationBuilder (spec → VZVirtualMachineConfiguration), HostResources
    Install/              MacOSInstaller, RestoreImageDownloader, WindowsUnattend, InstallMediaBuilder
    Runtime/              VMSession (one live machine, @MainActor), main-queue wrappers
  Nafitha/                SwiftUI app: library, detail, new-machine wizard, machine window
Resources/<lang>.lproj    translations
Support/                  Info.plist, entitlements
```

Virtualization.framework requires every call to a machine to happen on the queue that created it. Nafitha creates machines on the main queue, keeps `VMSession` on `@MainActor`, and calls the framework's completion-handler APIs through `VZMainQueue.swift` instead of its nonisolated `async` overlays.

## Not supported, by design of Virtualization.framework

- DirectX/3D acceleration for Windows guests
- Bridged networking (needs a restricted entitlement from Apple; Nafitha uses NAT)
- USB device passthrough
- x86/x64 guests (Apple silicon virtualizes ARM64 only)

## Contributing

Contributions of every size are welcome, including translations. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
