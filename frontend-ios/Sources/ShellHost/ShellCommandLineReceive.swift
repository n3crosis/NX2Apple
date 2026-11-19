import Foundation

/// Downloads a sharing invitation to scratch without installing or changing publisher identity.
public enum ShellCommandLineReceive {
    public enum Failure: Error { case untrustedPackage, externalPermissionRequired }

    /// The caller owns the returned archive and removes it after import/export finishes.
    public static func fetch(_ url: URL, in temporaryRoot: URL, allowExternal: Bool, allowUntrusted: Bool = false,
                             remoteTransport: GamePackageShareClient.RemoteTransport? = nil,
                             progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws -> URL {
        let invitation = try validatedInvitation(url, allowExternal: allowExternal)
        guard temporaryRoot.isFileURL else { throw GamePackageError.invalid("receive scratch must be a file URL") }
        try Task.checkCancellation()
        let fm = FileManager.default
        let id = UUID().uuidString.lowercased()
        let work = temporaryRoot.appendingPathComponent(".nxb-receive-" + id, isDirectory: true)
        let output = temporaryRoot.appendingPathComponent("received-" + id + ".nxb")
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let client = try GamePackageShareClient(url: invitation, remote: invitation.scheme == "https",
                                               remoteTransport: remoteTransport)
        do {
            let result = try await withTaskCancellationHandler {
                let preview = try await client.preview()
                guard allowUntrusted || preview.publisher?.trusted == true else { throw Failure.untrustedPackage }
                let received = try await client.receive(in: work, progress: progress)
                try Task.checkCancellation()
                let partial = work.appendingPathComponent("archive.partial")
                guard fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw GamePackageError.invalid("cannot create received archive")
                }
                let handle = try FileHandle(forWritingTo: partial)
                defer { try? handle.close() }
                // No proof override: streamDirectory retains the sender's exact manifest and proof.
                try GamePackage.streamDirectory(received) { bytes in
                    try Task.checkCancellation()
                    try handle.write(contentsOf: bytes)
                }
                try handle.synchronize()
                try handle.close()
                try Task.checkCancellation()
                try fm.moveItem(at: partial, to: output)
                return output
            } onCancel: {
                Task { await client.cancel() }
            }
            await client.cancel()
            if Task.isCancelled {
                try? fm.removeItem(at: result)
                throw CancellationError()
            }
            return result
        } catch {
            await client.cancel()
            throw error
        }
    }

    /// Pure validation shared with tests. Remote permission is never implied by an app wrapper.
    static func validatedInvitation(_ url: URL, allowExternal: Bool) throws -> URL {
        let invitation: URL
        if url.scheme?.lowercased() == "nx2apple" {
            invitation = try GamePackageReceiveLink.invitation(from: url)
        } else {
            invitation = url
        }
        let remote = invitation.scheme == "https"
        _ = try GamePackageShareInvitation(url: invitation, remote: remote)
        guard !remote || allowExternal else {
            throw Failure.externalPermissionRequired
        }
        return invitation
    }
}
