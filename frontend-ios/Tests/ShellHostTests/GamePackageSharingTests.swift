import XCTest
@testable import ShellHost

final class GamePackageSharingTests: XCTestCase {
    func testSharedGenerationSurvivesOtherWindowPruningUntilLastLeaseEnds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("0100000000001000/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = GamePackageLibrary(root: root)
        GamePackageLibrary.retainSharing(directory)
        GamePackageLibrary.retainSharing(directory)
        try library.prune(preserving: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        GamePackageLibrary.releaseSharing(directory)
        try library.prune(preserving: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        GamePackageLibrary.releaseSharing(directory)
        try library.prune(preserving: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testInvitationRequiresPinnedTLSAndLANAddress() throws {
        let credentials = String(repeating: "a", count: 64) + "." + String(repeating: "b", count: 64)
        let invitation = try GamePackageShareInvitation(url: XCTUnwrap(URL(string: "https://192.168.1.2:8443/nxb/1#\(credentials)")))
        XCTAssertNil(invitation.address.fragment)
        for address in ["http://192.168.1.2:8443/nxb/1", "https://example.com:8443/nxb/1",
                        "https://127.0.0.1:8443/nxb/1", "https://192.168.foo.1.2:8443/nxb/1", "https://192.168.1.2:8443/other",
                        "https://192.168.1.2:8443/nxb/1?token=secret"] {
            XCTAssertThrowsError(try GamePackageShareInvitation(url: XCTUnwrap(URL(string: "\(address)#\(credentials)"))))
        }
        XCTAssertThrowsError(try GamePackageShareInvitation(url: XCTUnwrap(URL(string: "https://192.168.1.2:8443/nxb/1#missing-pin"))))
    }
}
