// Boots a Linux ISO headlessly through the same VMSession the app uses, waits for an expected
// string on the serial console, then exercises suspend/resume and force stop.
//
// Usage: nafitha-smoke <iso> [--expect TEXT] [--timeout SECONDS] [--dir PATH] [--keep]
// Must run signed with the virtualization entitlement (see scripts/smoke.sh).

import Foundation
import NafithaCore

@MainActor
func waitFor(_ description: String, timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(250))
    }
    print("✗ timed out after \(Int(timeout))s waiting for \(description)")
    return false
}

func consoleText(_ bundle: VMBundle) -> String {
    (try? String(contentsOf: bundle.consoleLogURL, encoding: .utf8)) ?? ""
}

@MainActor
func run() async -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let isoPath = arguments.first, !isoPath.hasPrefix("--") else {
        print("usage: nafitha-smoke <iso> [--expect TEXT] [--timeout SECONDS] [--dir PATH] [--keep]")
        return 64
    }
    arguments.removeFirst()
    var expect = "login:"
    var timeout: TimeInterval = 120
    var keep = false
    var parent = FileManager.default.temporaryDirectory
    while !arguments.isEmpty {
        switch arguments.removeFirst() {
        case "--expect": expect = arguments.removeFirst()
        case "--timeout": timeout = TimeInterval(arguments.removeFirst()) ?? timeout
        case "--keep": keep = true
        case "--dir": parent = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
        case let other: print("unknown option \(other)"); return 64
        }
    }

    let root = parent.appending(path: "nafitha-smoke-\(UUID().uuidString)")
    let library = VMLibrary(rootURL: root)
    defer {
        if keep { print("kept \(root.path)") } else { try? FileManager.default.removeItem(at: root) }
    }

    var spec = VMSpec(name: "Smoke", guestOS: .linux, cpuCount: 2, memorySize: 2 * .gibibyte, diskSize: 8 * .gibibyte)
    spec.installMediaPath = URL(fileURLWithPath: isoPath).standardizedFileURL.path
    spec.bootFromInstallMedia = true
    spec.audioEnabled = false
    spec.sharedFolders = [SharedFolder(path: root.path, readOnly: true)]

    let bundle: VMBundle
    do {
        bundle = try library.create(spec: spec)
    } catch {
        print("✗ create: \(error.localizedDescription)")
        return 1
    }
    print("• bundle \(bundle.url.path)")

    let session = VMSession(bundle: bundle)
    let started = Date()
    await session.start()
    if case .failed(let message) = session.state {
        print("✗ start: \(message)")
        return 1
    }
    print("✓ started (\(session.state))")

    let booted = await waitFor("\"\(expect)\" on the console", timeout: timeout) {
        consoleText(bundle).contains(expect) || !session.state.isActive
    }
    let log = consoleText(bundle)
    print("— console (\(log.utf8.count) bytes), last lines —")
    print(log.split(separator: "\n", omittingEmptySubsequences: false).suffix(15).joined(separator: "\n"))
    print("—")
    guard booted, log.contains(expect) else {
        print("✗ boot: state \(session.state)")
        await session.forceStop()
        return 1
    }
    print(String(format: "✓ reached \"%@\" in %.1fs", expect, Date().timeIntervalSince(started)))

    var failures = 0
    if session.canSuspend {
        await session.suspend()
        if session.state == .stopped, bundle.hasSavedState {
            print("✓ suspended to \(bundle.savedStateURL.lastPathComponent)")
            await session.start()
            if session.state == .running, !bundle.hasSavedState {
                print("✓ resumed from saved state")
            } else {
                print("✗ resume: state \(session.state), saved state still present: \(bundle.hasSavedState)")
                failures += 1
            }
        } else {
            print("✗ suspend: \(session.lastError ?? "state \(session.state)")")
            print(session.state == .running ? "✓ machine kept running after the failed suspend" : "✗ machine not running after the failed suspend: \(session.state)")
            failures += 1
        }
    } else {
        print("• suspend not supported by this configuration (skipped)")
    }

    await session.forceStop()
    if session.state == .stopped {
        print("✓ force stopped")
    } else {
        print("✗ stop: state \(session.state)")
        failures += 1
    }
    return failures == 0 ? 0 : 1
}

exit(await run())
