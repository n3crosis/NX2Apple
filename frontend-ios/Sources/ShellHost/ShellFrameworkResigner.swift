import Foundation
import NativeSigning

enum ShellSigningError: Error { case signature(String), invalid(String) }

/// Re-signs private staged copies only. Never operate on an installed or loaded image.
public struct ShellFrameworkResigner: Sendable {
    public struct Identity: Sendable {
        public let pkcs12: URL
        public let profile: URL
        public let password: String
        public init(pkcs12: URL, profile: URL, password: String) {
            self.pkcs12 = pkcs12; self.profile = profile; self.password = password
        }
    }

    public static var isAvailable: Bool { nx_shell_signer_available() != 0 }
    private let identity: @Sendable () throws -> Identity

    /// Caller supplies an explicitly imported local identity. No automatic key,
    /// profile, account, keychain or network discovery occurs here.
    public init(identity: @escaping @Sendable () throws -> Identity) {
        self.identity = identity
    }

    /// Password/keypair/profile/team preflight. Does not prove Apple trust.
    public static func validateIdentity(_ identity: Identity, expectedTeamID: String) throws {
        guard isAvailable, identity.pkcs12.isFileURL, identity.profile.isFileURL,
              !identity.password.contains("\0"), !expectedTeamID.isEmpty,
              !expectedTeamID.contains("\0") else { throw ShellSigningError.signature("signing identity unavailable") }
        var message = [CChar](repeating: 0, count: 1024)
        let result = nx_shell_check_identity(identity.pkcs12.path, identity.password,
                                               identity.profile.path, expectedTeamID, &message, message.count)
        guard result == 0 else { throw ShellSigningError.signature("signing identity password, profile or team is invalid") }
    }

    public func sign(framework: URL, expectedTeamID: String) throws {
        guard Self.isAvailable else {
            throw ShellSigningError.signature("embedded zsign/OpenSSL backend is unavailable")
        }
        guard !expectedTeamID.isEmpty, !expectedTeamID.contains("\0") else { throw ShellSigningError.signature("missing host signing team") }
        let files = try Self.nativeFiles(framework: framework)
        let identifier = try Self.bundleIdentifier(framework: framework)
        let credentials = try identity()
        guard credentials.pkcs12.isFileURL, credentials.profile.isFileURL,
              !credentials.password.contains("\0") else { throw ShellSigningError.signature("invalid local identity") }
        for file in files {
            var message = [CChar](repeating: 0, count: 1024)
            let result = nx_shell_sign_library(file.path, credentials.pkcs12.path, credentials.password,
                                                credentials.profile.path, expectedTeamID, identifier,
                                                &message, message.count)
            guard result == 0 else {
                throw ShellSigningError.signature(String(decoding: message.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            guard FrameworkSignature.inspect(executable: file)?.teamID == expectedTeamID else {
                throw ShellSigningError.signature("signed image team mismatch")
            }
            try Self.validate(file)
        }
    }

    /// Bound the metadata read itself, not only a prior file size check.
    static func bundleIdentifier(framework: URL) throws -> String {
        let limit = 1 << 20
        let url = framework.appendingPathComponent("Info.plist")
        guard (((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? (limit + 1)) <= limit else { throw ShellSigningError.invalid("framework metadata too large") }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let data = try input.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ShellSigningError.invalid("framework metadata too large") }
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let identifier = info?["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              identifier.utf8.count <= 255, !identifier.contains("\0") else {
            throw ShellSigningError.invalid("framework bundle identifier")
        }
        return identifier
    }

    static func nativeFiles(framework: URL) throws -> [URL] {
        let fm = FileManager.default
        guard framework.isFileURL,
              try fm.attributesOfItem(atPath: framework.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ShellSigningError.invalid("staged framework directory")
        }
        // Do not skip hidden entries. Reject links and unusual filesystem types
        // even when they would not otherwise be selected for signing.
        var result: [URL] = []
        var count = 0
        func visit(_ directory: URL, depth: Int = 0) throws {
            guard depth <= 64 else { throw ShellSigningError.invalid("framework nesting limit") }
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                count += 1
                guard count <= 100_000 else { throw ShellSigningError.invalid("framework entry limit") }
                let attributes = try fm.attributesOfItem(atPath: file.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: try visit(file, depth: depth + 1)
                case .typeRegular:
                    guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                        throw ShellSigningError.invalid("hard-linked staged file")
                    }
                    if try Self.isLibrary(file) { result.append(file) }
                default: throw ShellSigningError.invalid("non-regular staged framework entry")
                }
            }
        }
        try visit(framework)
        guard !result.isEmpty else { throw ShellSigningError.invalid("framework has no native library") }
        return result.sorted { $0.path < $1.path }
    }
    static func isLibrary(_ url: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let bytes = [UInt8](try input.read(upToCount: 16) ?? Data())
        guard bytes.count == 16 else { return false }
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        guard word(0) == 0xfeedfacf, word(4) == 0x0100000c else { return false }
        guard [UInt32(6), 8].contains(word(12)) else { throw ShellSigningError.invalid("not a library") }
        return true
    }

    static func validate(_ url: URL) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard nx_shell_validate(url.path, &error, error.count) == 0 else {
            throw ShellSigningError.signature("iOS rejected the signed library")
        }
    }

}
