import Foundation

/// Downloads a sharing invitation to scratch without installing or changing publisher identity.
public enum ShellCommandLineReceive {
    public enum Failure: Error { case untrustedPackage, externalPermissionRequired }

    /// The caller owns the returned staging directory.
    static func fetch(_ url: URL, in libraryRoot: URL, allowExternal: Bool, allowUntrusted: Bool,
                      remoteTransport: GamePackageShareClient.RemoteTransport?,
                      checkCompatibility: @Sendable (GamePackageManifest) async throws -> Void,
                      progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws -> URL {
        let invitation = try validatedInvitation(url, allowExternal: allowExternal)
        try Task.checkCancellation()
        let client = try GamePackageShareClient(url: invitation, remote: invitation.scheme == "https",
                                               remoteTransport: remoteTransport)
        do {
            let directory = try await withTaskCancellationHandler {
                let preview = try await client.manifestPreview()
                guard allowUntrusted || preview.publisher?.trusted == true else { throw Failure.untrustedPackage }
                try await checkCompatibility(preview.manifest)
                try Task.checkCancellation()
                return try await client.receive(in: libraryRoot, progress: progress)
            } onCancel: {
                Task { await client.cancel() }
            }
            await client.cancel()
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: directory)
                throw CancellationError()
            }
            return directory
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
