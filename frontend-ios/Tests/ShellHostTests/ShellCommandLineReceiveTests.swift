import CryptoKit
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

    private func fixture() throws -> (GamePackageManifest, Data, [Data]) {
        let payloads = [
            Data(#"{"title_id":"0100000000001000","name":"Fixture","dylib":"nxgame.dylib"}"#.utf8),
            Data(repeating: 5, count: 32),
            Data("cover".utf8)
        ]
        let paths = ["run/game.json", "run/nxgame.dylib", "run/icon.jpg"]
        let files = zip(paths, payloads).map { pair in
            let (path, bytes) = pair
            return GamePackageManifest.File(path: path, bytes: UInt64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                executable: path == "run/nxgame.dylib")
        }
        let manifest = GamePackageManifest(titleID: "0100000000001000", name: "Fixture",
            minOS: "26.0", runtimeRevision: String(repeating: "a", count: 40), runtimeABI: 1, files: files)
        return (manifest, try JSONEncoder().encode(manifest), payloads)
    }

    func testIncompatibleManifestStopsBeforeAnyPayloadOrStaging() async throws {
        let (manifest, raw, _) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let invite = try XCTUnwrap(URL(string: "https://fixture.trycloudflare.com/nxb/1#" + token))
        do {
            _ = try await ShellCommandLineReceive.fetch(invite, in: root, allowExternal: true, allowUntrusted: true,
                remoteTransport: { url, _, _ in
                    switch url.lastPathComponent {
                    case "manifest": return raw
                    case "proof": return Data()
                    default: XCTFail("Incompatible package must not request payload, including cover"); throw URLError(.badURL)
                    }
                }, checkCompatibility: { received in
                    XCTAssertEqual(received, manifest)
                    throw PackageCommandLineImportError.compatibility
                }, progress: { _, _ in XCTFail("No download expected") })
            XCTFail("Incompatible package must be rejected")
        } catch PackageCommandLineImportError.compatibility {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testReceiveStagesVerifiedFilesWithoutRepacking() async throws {
        let (manifest, raw, payloads) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let invite = try XCTUnwrap(URL(string: "https://fixture.trycloudflare.com/nxb/1#" + token))
        let directory = try await ShellCommandLineReceive.fetch(invite, in: root, allowExternal: true, allowUntrusted: true,
            remoteTransport: { url, _, _ in
                switch url.lastPathComponent {
                case "manifest": return raw
                case "proof": return Data()
                default:
                    let index = try XCTUnwrap(Int(url.deletingLastPathComponent().lastPathComponent))
                    return try XCTUnwrap(payloads.indices.contains(index) ? payloads[index] : nil)
                }
            }, checkCompatibility: { XCTAssertEqual($0, manifest) }, progress: { _, _ in })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [directory.lastPathComponent])
        let library = GamePackageLibrary(root: root)
        var verified: UInt64 = 0
        let total = manifest.files.reduce(UInt64(0)) { $0 + $1.bytes }
        let prepared = try library.prepareDirectory(directory) { done, expected in
            XCTAssertGreaterThan(done, verified)
            XCTAssertEqual(expected, total)
            verified = done
        }
        XCTAssertEqual(verified, total)
        XCTAssertEqual(prepared.preview.manifest, manifest)
        XCTAssertNil(prepared.preview.publisher)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("nxb.json")), raw)
        let entry = try library.install(prepared, replaceExisting: false, checkCompatibility: { XCTAssertEqual($0, manifest) },
                                        sign: { _ in })
        XCTAssertEqual(library.entries().map(\.id), [manifest.titleID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.archive.path))
        XCTAssertEqual(try Data(contentsOf: entry.runRoot.appendingPathComponent("nxgame.dylib")), payloads[1])
    }
}
