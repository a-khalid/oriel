import Foundation

/// Downloads a macOS restore image (~15 GB) with progress, reusing a cached copy when present.
public final class RestoreImageDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static var cacheDirectory: URL {
        URL.cachesDirectory.appending(path: "Oriel/RestoreImages", directoryHint: .isDirectory)
    }

    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var destination: URL?
    private var movedFile: URL?

    public init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    public static func cachedURL(for remoteURL: URL) -> URL {
        cacheDirectory.appending(path: remoteURL.lastPathComponent)
    }

    public func download(_ remoteURL: URL) async throws -> URL {
        let target = Self.cachedURL(for: remoteURL)
        if FileManager.default.fileExists(atPath: target.path) {
            progress(1)
            return target
        }
        try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: remoteURL)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    self.destination = target
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it now.
        guard let destination = lock.withLock({ self.destination }) else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { movedFile = destination }
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
        } else if let status = (task.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            finish(.failure(URLError(.badServerResponse)))
        } else if let file = lock.withLock({ movedFile }) {
            finish(.success(file))
        } else {
            finish(.failure(URLError(.cannotCreateFile)))
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, any Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
