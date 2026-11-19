import XCTest
@testable import ShellHost

final class ShellCommandLineReceiveTests: XCTestCase {
    private let token = String(repeating: "b", count: 64)

    private func wrap(_ invitation: URL) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "nx2apple"
        parts.host = "receive"
        parts.queryItems = [URLQueryItem(name: "url", value: invitation.absoluteString)]
        return try XCTUnwrap(parts.url)
    }

    func testLANPlainAndWrappedNeedNoExternalPermission() throws {
        let plain = try XCTUnwrap(URL(string: "http://192.168.1.2:8443/nxb/1#" + token))
        for url in [plain, try wrap(plain)] {
            XCTAssertEqual(try ShellCommandLineReceive.validatedInvitation(url, allowExternal: false), plain)
            XCTAssertEqual(try ShellCommandLineReceive.validatedInvitation(url, allowExternal: true), plain)
        }
    }

    func testRemotePlainAndWrappedRequireExplicitPermission() throws {
        let plain = try XCTUnwrap(URL(string: "https://test-share.trycloudflare.com/nxb/1#" + token))
        for url in [plain, try wrap(plain)] {
            XCTAssertThrowsError(try ShellCommandLineReceive.validatedInvitation(url, allowExternal: false))
            XCTAssertEqual(try ShellCommandLineReceive.validatedInvitation(url, allowExternal: true), plain)
        }
    }

    func testExternalFlagDoesNotRelaxAddressOrEnvelopeValidation() throws {
        for text in ["https://example.com/nxb/1#" + token,
                     "http://127.0.0.1:8443/nxb/1#" + token,
                     "file:///tmp/game.nxb", "nx2apple://receive?url=bad&url=other"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertThrowsError(try ShellCommandLineReceive.validatedInvitation(url, allowExternal: true))
        }
    }
}
