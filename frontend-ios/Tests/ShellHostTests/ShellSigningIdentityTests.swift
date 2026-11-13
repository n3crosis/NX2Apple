import XCTest
@testable import ShellHost

final class ShellSigningIdentityTests: XCTestCase {
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

    func testUnavailableBackendCannotSaveIdentity() throws {
        guard !ShellFrameworkResigner.isAvailable else { throw XCTSkip("embedded signer enabled") }
        let store = ShellSigningIdentityStore(bundleID: "test.shell." + UUID().uuidString)
        XCTAssertThrowsError(try store.save(pkcs12: Data([0]), profile: Data([0]), password: "test-only",
                                            expectedTeamID: "TESTTEAM01")) { error in
            guard case ShellSigningIdentityStore.Failure.unavailable = error else {
                return XCTFail("Expected unavailable signing backend")
            }
        }
        XCTAssertFalse(store.hasIdentity)
    }

    func testMissingIdentityCannotSign() {
        let store = ShellSigningIdentityStore(bundleID: "test.shell." + UUID().uuidString)
        XCTAssertThrowsError(try store.sign(framework: URL(fileURLWithPath: "/unused"), expectedTeamID: "TESTTEAM01"))
    }
}
