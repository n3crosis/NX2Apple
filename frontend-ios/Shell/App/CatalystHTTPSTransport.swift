#if targetEnvironment(macCatalyst)
import Foundation

/// One CLI receive owns one transport, serializing requests and reusing TLS
/// connections. Never selected by GUI or iPhone networking.
final class CatalystHTTPSTransport: @unchecked Sendable {
    enum Failure: LocalizedError {
        case request
        var errorDescription: String? { "HTTPS transfer failed. Check the sharing session and network connection." }
    }
    private let queue = DispatchQueue(label: "org.nx2apple.cli.https")
    private let client = DMCatalystHTTPSClient()

    /// authorization is the invitation's 64-character token, without Bearer prefix.
    func get(_ url: URL, authorization: String, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw Failure.request }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let data = client.fetch(url, authorization: authorization, maximumBytes: maximumBytes) {
                        continuation.resume(returning: data)
                    } else if client.failure == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: Failure.request)
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    /// Permanently cancels this receive's active and queued requests.
    func cancel() { client.cancel() }
}
#endif
