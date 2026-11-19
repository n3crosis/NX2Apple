import XCTest
@testable import ShellHost

final class GamePackageSharingTests: XCTestCase {
    #if os(macOS)
    @MainActor func testExportShareCompletionRunsOnceOnCancellationOrFailure() {
        var callbacks = 0
        var reported: Error?
        let coordinator = PackageExportShareSheet.Coordinator { error in
            callbacks += 1
            reported = error
        }
        let failure = CocoaError(.fileReadNoPermission)
        coordinator.finish(failure)
        coordinator.finish(nil)
        XCTAssertEqual(callbacks, 1, "Archive cleanup must not race repeated sharing callbacks")
        XCTAssertEqual((reported as NSError?)?.code, failure.errorCode)
    }
    #endif

    @MainActor func testFilePickerCancellationIsNotAnImportFailure() {
        XCTAssertNil(GamePackageReceiveView.importFailureMessage(CocoaError(.userCancelled)))
        XCTAssertNil(GamePackageReceiveView.importFailureMessage(URLError(.cancelled)))
        let unreadable = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                                 userInfo: [NSLocalizedDescriptionKey: "Cannot read package"])
        XCTAssertEqual(GamePackageReceiveView.importFailureMessage(unreadable), "Cannot read package")
    }

    func testLocalTransferWaitsForPermissionWithoutChangingRemoteTimeouts() {
        let local = GamePackageShareClient.sessionConfiguration(remote: false)
        XCTAssertTrue(local.waitsForConnectivity)
        XCTAssertEqual(local.timeoutIntervalForResource, 60)
        XCTAssertNil(local.urlCache)
        XCTAssertNil(local.httpCookieStorage)
        let remote = GamePackageShareClient.sessionConfiguration(remote: true)
        XCTAssertFalse(remote.waitsForConnectivity)
        XCTAssertEqual(remote.timeoutIntervalForResource, 60)
    }

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

    func testFileLeaseSurvivesStoppingConcurrentLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("0100000000001000/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = GamePackageLibrary(root: root)
        GamePackageLibrary.retainSharing(directory) // link
        GamePackageLibrary.retainSharing(directory) // file export
        GamePackageLibrary.releaseSharing(directory) // Stop sharing
        defer { GamePackageLibrary.releaseSharing(directory) }
        try library.prune(preserving: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testInvitationRequiresTokenAndLANAddress() throws {
        let credentials = String(repeating: "b", count: 64)
        let invitation = try GamePackageShareInvitation(url: XCTUnwrap(URL(string: "http://192.168.1.2:8443/nxb/1#\(credentials)")))
        XCTAssertNil(invitation.address.fragment)
        XCTAssertEqual(invitation.token, credentials)
        for address in ["https://192.168.1.2:8443/nxb/1", "http://example.com:8443/nxb/1",
                        "http://127.0.0.1:8443/nxb/1", "http://192.168.foo.1.2:8443/nxb/1", "http://192.168.1.2:8443/other",
                        "http://192.168.1.2:8443/nxb/1?token=secret"] {
            XCTAssertThrowsError(try GamePackageShareInvitation(url: XCTUnwrap(URL(string: "\(address)#\(credentials)"))))
        }
        XCTAssertThrowsError(try GamePackageShareInvitation(url: XCTUnwrap(URL(string: "http://192.168.1.2:8443/nxb/1#missing-token"))))
    }
    func testRemoteInvitationRequiresExplicitHTTPSCloudflareMode() throws {
        let token = String(repeating: "b", count: 64)
        let url = try XCTUnwrap(URL(string: "https://sample-name.trycloudflare.com/nxb/1#\(token)"))
        XCTAssertThrowsError(try GamePackageShareInvitation(url: url))
        let invitation = try GamePackageShareInvitation(url: url, remote: true)
        XCTAssertEqual(invitation.token, token)
        XCTAssertNil(invitation.address.fragment)
        for origin in ["http://sample.trycloudflare.com", "https://trycloudflare.com", "https://sample.trycloudflare.com.evil.com",
                       "https://a.b.trycloudflare.com", "https://sample.trycloudflare.com:8443", "https://192.168.1.2:443"] {
            XCTAssertThrowsError(try GamePackageShareInvitation(
                url: XCTUnwrap(URL(string: "\(origin)/nxb/1#\(token)")), remote: true))
        }
    }

    func testInjectedRemoteTransportReceivesOnlyValidatedAddressAndBound() async throws {
        let token = String(repeating: "b", count: 64)
        let url = try XCTUnwrap(URL(string: "https://fixture.trycloudflare.com/nxb/1#\(token)"))
        let client = try GamePackageShareClient(url: url, remote: true) { address, credential, limit in
            XCTAssertEqual(address.absoluteString, "https://fixture.trycloudflare.com/nxb/1/metadata/manifest")
            XCTAssertEqual(credential, token)
            XCTAssertEqual(limit, 8 << 20)
            return Data(repeating: 0, count: limit + 1)
        }
        do {
            _ = try await client.preview()
            XCTFail("Oversized body must not be parsed")
        } catch GamePackageError.invalid(let reason) {
            XCTAssertEqual(reason, "shared response too large")
        }
    }

}
