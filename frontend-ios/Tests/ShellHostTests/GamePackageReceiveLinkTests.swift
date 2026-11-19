import XCTest
@testable import ShellHost

final class GamePackageReceiveLinkTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)

    private func wrapper(_ invitation: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "nx2apple"
        parts.host = "receive"
        parts.queryItems = [URLQueryItem(name: "url", value: invitation)]
        return try XCTUnwrap(parts.url)
    }

    func testLANAndRemoteInvitationRoundTripPreservesFragment() throws {
        for address in ["http://192.168.1.2:8443/nxb/1", "https://test-share.trycloudflare.com/nxb/1"] {
            let invitation = address + "#" + token
            let link = try wrapper(invitation)
            XCTAssertNil(URLComponents(url: link, resolvingAgainstBaseURL: false)?.fragment)
            XCTAssertEqual(try GamePackageReceiveLink.invitation(from: link).absoluteString, invitation)
        }
    }

    @MainActor func testReceiveOnlyQueuesPrefillAndDoesNotStartImport() throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config())
        let invitation = "https://test-share.trycloudflare.com/nxb/1#" + token
        model.importingSigningIdentity = true
        XCTAssertTrue(model.handleReceiveLink(try wrapper(invitation)))
        XCTAssertEqual(model.pendingReceiveLink, invitation)
        XCTAssertFalse(model.canPreparePackage, "Busy UI must defer presentation")
        XCTAssertFalse(model.importingPackage)
        XCTAssertFalse(model.hasExternalPackage)
        XCTAssertNil(model.packagePreview)
        XCTAssertTrue(model.packages.isEmpty)
        XCTAssertFalse(model.handleReceiveLink(try XCTUnwrap(URL(string: "nx2apple://receive?url=invalid"))))
        XCTAssertEqual(model.pendingReceiveLink, invitation, "Invalid opens must not overwrite a valid pending invitation")
        model.importingSigningIdentity = false
        XCTAssertTrue(model.canPreparePackage)
    }

    func testRejectsAmbiguousOuterRoutes() throws {
        let valid = try wrapper("http://192.168.1.2:8443/nxb/1#" + token).absoluteString
        for invalid in [
            valid.replacingOccurrences(of: "nx2apple://receive?", with: "other://receive?"),
            valid.replacingOccurrences(of: "receive?", with: "launch?"),
            valid.replacingOccurrences(of: "receive?", with: "user@receive?"),
            valid.replacingOccurrences(of: "receive?", with: "receive:443?"),
            valid.replacingOccurrences(of: "receive?", with: "receive:?"),
            valid.replacingOccurrences(of: "receive?", with: "receive/?"),
            valid + "#ignored", valid + "&url=anything", valid + "&extra=1",
            "nx2apple://receive?url", "nx2apple://receive?url=", "nx2apple://receive"
        ] {
            XCTAssertThrowsError(try GamePackageReceiveLink.invitation(from: XCTUnwrap(URL(string: invalid))), invalid)
        }
    }

    func testRejectsInvalidInnerInvitations() throws {
        for invalid in [
            "http://127.0.0.1:8443/nxb/1#" + token,
            "http://example.com:8443/nxb/1#" + token,
            "https://example.com/nxb/1#" + token,
            "https://a.trycloudflare.com.evil.example/nxb/1#" + token,
            "http://192.168.1.2:8443/other#" + token,
            "http://192.168.1.2:8443/nxb/1#bad",
            "http://192.168.1.2:8443/nxb/1?extra=1#" + token,
            "nx2apple://receive?url=anything"
        ] {
            XCTAssertThrowsError(try GamePackageReceiveLink.invitation(from: wrapper(invalid)))
        }
    }
}
