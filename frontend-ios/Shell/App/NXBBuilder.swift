#if canImport(NxkitBuilder)
import Foundation
import NxkitBuilder
import ShellHost

/// Builds only game-specific code and resources. Runtime compatibility values
/// must describe the runtime embedded in this app, not a guessed upstream version.
struct NXBBuilder {
    struct Request: Encodable, Sendable {
        var input: String
        var keys: String
        var work: String
        var output: String
        var updates: [String] = []
        var dlc: [String] = []
        var titleID: String?
        var basePackage: String?
        var runtimeABI: UInt32
        var runtimeRevision: String
        var generation: String = UUID().uuidString.lowercased()
        var minOS: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class ProgressCallback: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func checkCancellation() throws { if isCancelled { throw CancellationError() } }
        let report: @Sendable (GameBuildProgress) -> Void
        init(_ report: @escaping @Sendable (GameBuildProgress) -> Void) { self.report = report }
    }

    private struct CompletedBuild: Codable {
        var runtimeABI: UInt32
        var runtimeRevision: String
        var minOS: String
        var size: UInt64
    }

    /// The caller retains security-scoped URL access until the build completes.
    /// Cancellation stops at the next safe stage boundary, never mid-native operation.
    static func prepare(_ request: Request, onProgress: @escaping @Sendable (GameBuildProgress) -> Void) async throws -> URL {
        let callback = ProgressCallback(onProgress)
        if Task.isCancelled { callback.cancel() }
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try callback.checkCancellation()
                var request = request
                let output = URL(fileURLWithPath: request.output)
                let completed = URL(fileURLWithPath: request.work).appendingPathComponent("completed-build.json")
                func outputSize() throws -> UInt64 {
                    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                    return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                }
                if let data = try? Data(contentsOf: completed),
                   let checkpoint = try? JSONDecoder().decode(CompletedBuild.self, from: data),
                   checkpoint.runtimeABI == request.runtimeABI,
                   checkpoint.runtimeRevision == request.runtimeRevision,
                   checkpoint.minOS == request.minOS,
                   checkpoint.size > 0, checkpoint.size == (try? outputSize()) {
                    try callback.checkCancellation()
                    onProgress(GameBuildProgress(stage: "prepared", message: ""))
                    return output
                }
                // An interrupted archive is not a completed build. Never reuse it.
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                if FileManager.default.fileExists(atPath: completed.path) { try FileManager.default.removeItem(at: completed) }
                try callback.checkCancellation()
                let totalFiles = 1 + request.updates.count + request.dlc.count
                var completedFiles = 0
                func reportInputs() {
                    onProgress(GameBuildProgress(stage: "inputs", message: "",
                                                 completedFiles: completedFiles, totalFiles: totalFiles))
                }
                reportInputs()
                let inputs = URL(fileURLWithPath: request.work).appendingPathComponent("inputs", isDirectory: true)
                // Rust reads package ranges repeatedly. Snapshot coordinated provider files
                // so downloads and external edits cannot change them between passes.
                func materialize(_ path: String, _ slot: String) throws -> String {
                    try callback.checkCancellation()
                    reportInputs()
                    let source = URL(fileURLWithPath: path)
                    let directory = inputs.appendingPathComponent(slot, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(source.lastPathComponent)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        completedFiles += 1
                        reportInputs()
                        return destination.path
                    }
                    let partial = directory.appendingPathComponent(".copying")
                    if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
                    try coordinatedRead(source) { try FileManager.default.copyItem(at: $0, to: partial) }
                    try FileManager.default.moveItem(at: partial, to: destination)
                    completedFiles += 1
                    reportInputs()
                    return destination.path
                }
                request.input = try materialize(request.input, "base")
                request.updates = try request.updates.enumerated().map { try materialize($0.element, "updates/\($0.offset)") }
                request.dlc = try request.dlc.enumerated().map { try materialize($0.element, "dlc/\($0.offset)") }
                // Keep the private keys coordinated for the native call, without copying
                // credentials into the working directory or distributable package.
                return try coordinatedRead(URL(fileURLWithPath: request.keys)) { keys in
                    request.keys = keys.path
                    let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
                    var error = [CChar](repeating: 0, count: 4096)
                    let capacity = error.count
                    let context = Unmanaged.passRetained(callback).toOpaque()
                    defer { Unmanaged<ProgressCallback>.fromOpaque(context).release() }
                    let status = json.withCString {
                        nxkit_prepare_nxb($0, &error, capacity, { stage, context in
                            guard let stage, let context else { return 0 }
                            let callback = Unmanaged<ProgressCallback>.fromOpaque(context).takeUnretainedValue()
                            guard !callback.isCancelled else { return 0 }
                            callback.report(GameBuildProgress(stage: String(cString: stage), message: ""))
                            return 1
                        }, context)
                    }
                    guard status == 0 else { throw Failure(message: String(cString: error)) }
                    let checkpoint = CompletedBuild(runtimeABI: request.runtimeABI,
                        runtimeRevision: request.runtimeRevision, minOS: request.minOS, size: try outputSize())
                    try JSONEncoder().encode(checkpoint).write(to: completed, options: .atomic)
                    try callback.checkCancellation()
                    onProgress(GameBuildProgress(stage: "prepared", message: ""))
                    return output
                }
            }.value
        } onCancel: {
            callback.cancel()
        }
    }

    private static func coordinatedRead<T>(_ url: URL, _ read: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result { try read(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure(message: "The selected file could not be read.") }
        return try result.get()
    }

}
#endif
