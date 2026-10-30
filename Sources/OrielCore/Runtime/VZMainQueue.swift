import Foundation
@preconcurrency import Virtualization

// Virtualization.framework must be driven from the queue the machine was created on (main here).
// The framework's own `async` overlays are nonisolated and may hop off the main thread, so these
// wrappers call the completion-handler APIs directly from the main actor.

@MainActor
extension VZVirtualMachine {
    func startOnMain(options: VZMacOSVirtualMachineStartOptions? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if let options {
                start(options: options) { error in continuation.resume(with: error.map(Result.failure) ?? .success(())) }
            } else {
                start { continuation.resume(with: $0) }
            }
        }
    }

    func pauseOnMain() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pause { continuation.resume(with: $0) }
        }
    }

    func resumeOnMain() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            resume { continuation.resume(with: $0) }
        }
    }

    func stopOnMain() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stop { error in continuation.resume(with: error.map(Result.failure) ?? .success(())) }
        }
    }

    func saveStateOnMain(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            saveMachineStateTo(url: url) { error in continuation.resume(with: error.map(Result.failure) ?? .success(())) }
        }
    }

    func restoreStateOnMain(from url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            restoreMachineStateFrom(url: url) { error in continuation.resume(with: error.map(Result.failure) ?? .success(())) }
        }
    }
}

@MainActor
extension VZMacOSInstaller {
    func installOnMain() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            install { continuation.resume(with: $0) }
        }
    }
}
