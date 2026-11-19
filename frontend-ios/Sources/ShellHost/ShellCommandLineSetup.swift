#if targetEnvironment(macCatalyst)
import Foundation

/// File-based setup for the signed Catalyst executable's pre-UI command mode.
/// Errors intentionally exclude credential contents, paths and underlying errors.
public enum ShellCommandLineSetup {
    public enum Failure: String, LocalizedError, Sendable {
        case signingIdentity = "Signing identity import failed. Check the files, password, host signing team and Keychain access."
        case buildKeys = "Build keys import failed. Choose a readable prod.keys file smaller than 1 MiB."
        public var errorDescription: String? { rawValue }
    }

    /// Return the app's existing key store path without copying credentials.
    public static func buildKeysURL() throws -> URL {
        let store = GameBuildKeys()
        guard store.exists else { throw Failure.buildKeys }
        return store.url
    }

    public static func validateSigningIdentity() async throws {
        try await Task.detached(priority: .userInitiated) {
            try ShellSigningIdentityStore().validateIdentity()
        }.value
    }

    public static func importSigningIdentity(pkcs12: URL, profile: URL, password: String) async throws {
        let work = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let identity = try ShellSigningIdentityStore.readImportedFile(pkcs12, maximumBytes: 1_048_576)
                let provisioning = try ShellSigningIdentityStore.readImportedFile(profile, maximumBytes: ProvisioningProfile.maxProfileBytes)
                try Task.checkCancellation()
                try ShellSigningIdentityStore().save(pkcs12: identity, profile: provisioning, password: password)
            } catch is CancellationError { throw CancellationError() }
            catch { throw Failure.signingIdentity }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    public static func importBuildKeys(from source: URL) async throws {
        let work = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                guard source.isFileURL else { throw Failure.buildKeys }
                // The shared save path performs one coordinated, bounded read.
                try GameBuildKeys().save(from: source)
            } catch is CancellationError { throw CancellationError() }
            catch { throw Failure.buildKeys }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
#endif
