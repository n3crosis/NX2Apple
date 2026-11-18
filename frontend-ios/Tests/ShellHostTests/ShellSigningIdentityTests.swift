import XCTest
import Security
@testable import ShellHost

final class ShellSigningIdentityTests: XCTestCase {
    @MainActor func testSigningFileExtensions() {
        XCTAssertEqual(ShellSigningIdentityView.fileExtensions(isProfile: true),
                       ["mobileprovision", "provisionprofile"])
        XCTAssertEqual(ShellSigningIdentityView.fileExtensions(isProfile: false), ["p12"])
    }

    func testImportedIdentityReadIsBoundedAndRejectsNonFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("identity.p12")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertEqual(try ShellSigningIdentityStore.readImportedFile(file, maximumBytes: 3), Data([1, 2, 3]))
        XCTAssertThrowsError(try ShellSigningIdentityStore.readImportedFile(file, maximumBytes: 2))
        try Data().write(to: file)
        XCTAssertThrowsError(try ShellSigningIdentityStore.readImportedFile(file, maximumBytes: 3))
        XCTAssertThrowsError(try ShellSigningIdentityStore.readImportedFile(directory, maximumBytes: 3))
        XCTAssertThrowsError(try ShellSigningIdentityStore.readImportedFile(file, maximumBytes: Int.max))
    }

    func testMissingIdentityCannotSign() {
        let store = ShellSigningIdentityStore(bundleID: "test.shell." + UUID().uuidString)
        XCTAssertThrowsError(try store.validateIdentity())
        XCTAssertThrowsError(try store.sign(framework: URL(fileURLWithPath: "/unused"), expectedTeamID: "TESTTEAM01"))
    }

    private func retainedCredentialData() throws -> Data {
        let expiration = Date(timeIntervalSinceNow: 3600)
        let profile = try syntheticProfile(expiration: expiration)
        XCTAssertGreaterThan(try XCTUnwrap(ShellImportedIdentityValidation.profileDictionary(profile)?["ExpirationDate"] as? Date), Date())
        // Retained storage bytes, not save(), whose import-time validation cannot
        // establish that the identity still matches a newly installed host.
        return try PropertyListSerialization.data(fromPropertyList: [
            "pkcs12": Data([1]), "profile": profile, "password": ""
        ], format: .binary, options: 0)
    }

    func testPersistedIdentityIsRevalidatedBeforeTouchingFramework() throws {
        let data = try retainedCredentialData()
        let store = ShellSigningIdentityStore(bundleID: "test.shell." + UUID().uuidString,
                                              credentialReader: { data })
        assertIdentityRevalidatedBeforeTouchingFramework(store)
    }

    func testMalformedPersistedIdentityCannotSign() {
        let store = ShellSigningIdentityStore(bundleID: "test.shell." + UUID().uuidString,
                                              credentialReader: { Data([1]) })
        XCTAssertThrowsError(try store.sign(framework: URL(fileURLWithPath: "/unused"), expectedTeamID: "TESTTEAM01")) {
            guard case ShellSigningIdentityStore.Failure.invalid = $0 else {
                return XCTFail("Expected persisted credential decoding to reject malformed bytes, got \($0)")
            }
        }
    }

    #if os(macOS)
    // Package tests can run without an entitled Keychain host. Keep real storage
    // integration here and run the signing regression above on both platforms.
    func testKeychainIdentityIsRevalidatedBeforeTouchingFramework() throws {
        let bundleID = "test.shell." + UUID().uuidString
        let store = ShellSigningIdentityStore(bundleID: bundleID)
        defer { try? store.remove() }
        let data = try retainedCredentialData()
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundleID + ".local-signing",
            kSecAttrAccount as String: "shell-owner-signing-v1",
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(request as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
        guard status == errSecSuccess else { return }
        assertIdentityRevalidatedBeforeTouchingFramework(store)
    }
    #endif

    private func assertIdentityRevalidatedBeforeTouchingFramework(_ store: ShellSigningIdentityStore,
                                                                 file: StaticString = #filePath, line: UInt = #line) {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".framework")
        XCTAssertThrowsError(try store.sign(framework: missing, expectedTeamID: "TESTTEAM01"), file: file, line: line) {
            guard let failure = $0 as? ShellSigningIdentityStore.Failure else {
                return XCTFail("Expected identity rejection before any framework file operation, got \($0)", file: file, line: line)
            }
            switch failure {
            case .hostSignatureUnavailable, .invalid, .signerMismatch, .certificateNotInProfile: break
            default: XCTFail("Expected current-host identity validation, got \(failure)", file: file, line: line)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), file: file, line: line)
    }

    /// An attached CMS payload with no signer or keys. It can supply an expiry
    /// to the old expiry-only check but cannot pass full identity validation.
    private func syntheticProfile(expiration: Date) throws -> Data {
        func der(_ tag: UInt8, _ content: Data) -> Data {
            var length = content.count
            var encoded: [UInt8] = []
            repeat {
                encoded.insert(UInt8(truncatingIfNeeded: length), at: 0)
                length >>= 8
            } while length > 0
            let size = content.count < 128 ? encoded : [0x80 | UInt8(encoded.count)] + encoded
            return Data([tag] + size) + content
        }
        let content = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": expiration], format: .xml, options: 0)
        let oid: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07]
        let payload = der(0x30, der(0x06, Data(oid + [1])) + der(0xa0, der(0x04, content)))
        let signed = der(0x30, der(0x02, Data([1])) + der(0x31, Data()) + payload + der(0x31, Data()))
        return der(0x30, der(0x06, Data(oid + [2])) + der(0xa0, signed))
    }
}
