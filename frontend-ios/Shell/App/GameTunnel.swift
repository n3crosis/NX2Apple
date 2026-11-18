#if canImport(GameTunnelC)
import Foundation
import GameTunnelC
import ShellHost

actor GameTunnel: GamePackageTunnel {
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit {
            // The actor releases ownership before this worker starts. No poll
            // may run after release, and the bounded shutdown never blocks UI.
            let address = UInt(bitPattern: pointer)
            DispatchQueue.global(qos: .utility).async {
                nx_game_tunnel_stop(OpaquePointer(bitPattern: address))
            }
        }
    }
    private var handle: Handle?

    func start(port: UInt16) async throws -> URL {
        try Task.checkCancellation()
        guard handle == nil, let pointer = nx_game_tunnel_start(port) else {
            throw CocoaError(.featureUnsupported)
        }
        let session = Handle(pointer)
        handle = session
        do {
            while handle === session {
                try Task.checkCancellation()
                var text = [CChar](repeating: 0, count: 2048)
                let capacity = text.count
                let status = nx_game_tunnel_poll(session.pointer, &text, capacity)
                if status == 1 {
                    let string = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    guard let url = URL(string: String(decoding: string, as: UTF8.self)),
                          url.scheme == "https", url.host?.hasSuffix(".trycloudflare.com") == true,
                          url.user == nil, url.password == nil else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return url
                }
                if status < 0 { throw URLError(.cannotConnectToHost) }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CancellationError()
        } catch {
            if handle === session { handle = nil }
            throw error
        }
    }

    func stop() { handle = nil }
}
#endif
