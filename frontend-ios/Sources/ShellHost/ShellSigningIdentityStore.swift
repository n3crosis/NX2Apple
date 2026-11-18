import Foundation
import Security

/// Owner-imported signing material, kept in a non-synchronizing device-only
/// Keychain item. No credentials or file locations belong in receipts or logs.
public struct ShellSigningIdentityStore: Sendable {
    public enum Failure: Error { case missing, invalid, storage, locked, expired
        case hostSignatureUnavailable, signerMismatch, certificateNotInProfile
    }
    private struct Credential: Codable {
        let pkcs12: Data
        let profile: Data
        let password: String
    }
    private static let temporaryLock = NSLock()
    private let service: String
    private let credentialReader: (@Sendable () throws -> Data)?
    private static let account = "shell-owner-signing-v1"
    public init(bundleID: String = Bundle.main.bundleIdentifier ?? "org.nxnative.shell") {
        service = bundleID + ".local-signing"
        credentialReader = nil
    }

    /// Storage-only seam for package tests without an entitled Keychain host.
    /// Decoding and current-host validation remain on the normal signing path.
    init(bundleID: String, credentialReader: @escaping @Sendable () throws -> Data) {
        service = bundleID + ".local-signing"
        self.credentialReader = credentialReader
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account, kSecAttrSynchronizable as String: false]
    }

    public var hasIdentity: Bool {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    /// Coordinate provider downloads off the main actor, retaining security scope
    /// until the bounded read completes. No credential URL is persisted.
    static func readImportedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, maximumBytes > 0, maximumBytes < Int.max else { throw Failure.invalid }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                let attributes = try FileManager.default.attributesOfItem(atPath: coordinatedURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.invalid }
                let input = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? input.close() }
                let data = try input.read(upToCount: maximumBytes + 1) ?? Data()
                guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.invalid }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.invalid }
        return try result.get()
    }

    public func save(pkcs12: Data, profile: Data, password: String) throws {
        guard !pkcs12.isEmpty, pkcs12.count <= 1024 * 1024,
              !profile.isEmpty, profile.count <= ProvisioningProfile.maxProfileBytes,
              password.utf8.count <= 4096, !password.contains("\0") else { throw Failure.invalid }
        try ShellImportedIdentityValidation.validate(pkcs12: pkcs12, profile: profile, password: password,
                                                     executable: Bundle.main.executableURL)
        let credential = Credential(pkcs12: pkcs12, profile: profile, password: password)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(credential)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.storage }
        } else if status != errSecSuccess { throw Failure.storage }
    }

    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.storage }
    }

    private func loadCredential() throws -> Credential {
        let data = try credentialReader?() ?? readKeychainData()
        do { return try PropertyListDecoder().decode(Credential.self, from: data) }
        catch { throw Failure.invalid }
    }

    private func readKeychainData() throws -> Data {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { throw Failure.missing }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.locked }
        return data
    }

    func identitySummary() -> (team: String, expiration: Date)? {
        guard let credential = try? loadCredential(),
              let profile = ShellImportedIdentityValidation.profileDictionary(credential.profile),
              let team = (profile["TeamIdentifier"] as? [String])?.first,
              let expiration = profile["ExpirationDate"] as? Date else { return nil }
        return (team, expiration)
    }

    /// The entire synchronous signing operation owns protected temporary files.
    /// Nothing is materialized in Documents, the import stage, or a shared group.
    public func sign(framework: URL, expectedTeamID: String) throws {
        try withIdentity { p12, profile, password in
            try ShellFrameworkResigner.sign(framework: framework, expectedTeamID: expectedTeamID,
                                            pkcs12: p12, profile: profile, password: password)
        }
    }

    /// Sign a private NXB game image without embedding a per-game framework.
    public func sign(library: URL, expectedTeamID: String) throws {
        try withIdentity { p12, profile, password in
            try ShellFrameworkResigner.sign(library: library, expectedTeamID: expectedTeamID,
                                            pkcs12: p12, profile: profile, password: password)
        }
    }

    /// Publisher authenticity is separate from executable signing and profile
    /// validity. An expired publisher certificate still proves the data signature.
    public func signPackageManifest(_ manifest: Data) throws -> Data {
        let credential = try loadCredential()
        var options: [String: Any] = [kSecImportExportPassphrase as String: credential.password]
        #if os(macOS)
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            throw Failure.invalid
        }
        #endif
        var imported: CFArray?
        guard SecPKCS12Import(credential.pkcs12 as CFData, options as CFDictionary, &imported) == errSecSuccess,
              let items = imported as? [[String: Any]],
              let value = items.first?[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else { throw Failure.invalid }
        return try GamePackageSignature.sign(manifest: manifest, identity: value as! SecIdentity)
    }

    func validateIdentity() throws {
        _ = try validatedCredential()
    }

    private func validatedCredential() throws -> Credential {
        let credential = try loadCredential()
        // The Keychain item can survive a shell update signed by a different
        // certificate on the same team. Match the currently installed host again.
        try ShellImportedIdentityValidation.validate(pkcs12: credential.pkcs12, profile: credential.profile,
                                                     password: credential.password, executable: Bundle.main.executableURL)
        return credential
    }

    private func withIdentity(_ operation: (URL, URL, String) throws -> Void) throws {
        let credential = try validatedCredential()
        Self.temporaryLock.lock()
        defer { Self.temporaryLock.unlock() }
        let fm = FileManager.default
        // A terminated import cannot run defer. Remove only our protected,
        // randomly named temporary directories before the next operation.
        for previous in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] {
            if previous.lastPathComponent.hasPrefix("shell-identity-"),
               UUID(uuidString: String(previous.lastPathComponent.dropFirst("shell-identity-".count))) != nil {
                try fm.removeItem(at: previous)
            }
        }
        let folder = fm.temporaryDirectory.appendingPathComponent("shell-identity-" + UUID().uuidString, isDirectory: true)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: attributes)
        defer { try? fm.removeItem(at: folder) }
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let p12 = folder.appendingPathComponent("identity.p12")
        let profile = folder.appendingPathComponent("profile.mobileprovision")
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try credential.pkcs12.write(to: p12, options: options)
        try credential.profile.write(to: profile, options: options)
        for file in [p12, profile] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        try operation(p12, profile, credential.password)
    }
}
