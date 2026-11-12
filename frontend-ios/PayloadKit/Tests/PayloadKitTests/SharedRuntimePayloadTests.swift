import XCTest
@testable import PayloadKit

extension PayloadTests {
    var sharedIdentity: PayloadSharedRuntime {
        .init(abi: 1, profileABI: 1, runtimeVersion: "fs1-test", chain: "b-0123456789ab")
    }

    func sharedFixture() throws -> (PayloadManifest, URL) {
        var (manifest, parent) = try fixture()
        let framework = parent.appendingPathComponent(manifest.framework)
        let path = framework.appendingPathComponent("game.manifest.json")
        var game = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        game["loader"] = "FS"
        game["chain"] = sharedIdentity.chain
        game["shared_runtime"] = ["abi": 1, "profile_abi": 1, "runtime_version": sharedIdentity.runtimeVersion]
        try JSONSerialization.data(withJSONObject: game).write(to: path)
        manifest.sharedRuntime = sharedIdentity
        manifest.schema = 2
        manifest.files = try PayloadArchive.fileList(framework: framework)
        return (manifest, parent)
    }

    func testSharedPayloadNegotiatesEveryIdentityField() throws {
        let (manifest, _) = try sharedFixture()
        var supported = host
        supported.sharedRuntime = sharedIdentity
        XCTAssertNoThrow(try manifest.compatible(with: supported))
        XCTAssertThrowsError(try manifest.compatible(with: host))
        for runtime in [PayloadSharedRuntime(abi: 2, profileABI: 1, runtimeVersion: "fs1-test", chain: sharedIdentity.chain),
                        .init(abi: 1, profileABI: 2, runtimeVersion: "fs1-test", chain: sharedIdentity.chain),
                        .init(abi: 1, profileABI: 1, runtimeVersion: "fs1-other", chain: sharedIdentity.chain),
                        .init(abi: 1, profileABI: 1, runtimeVersion: "fs1-test", chain: "b-abcdef")] {
            supported.sharedRuntime = runtime
            XCTAssertThrowsError(try manifest.compatible(with: supported))
        }
    }

    func testSharedPayloadCannotUseLegacySchemaOrStripRequirement() throws {
        let (manifest, parent) = try sharedFixture()
        var changed = manifest
        changed.schema = 1
        XCTAssertThrowsError(try changed.validate())
        changed.sharedRuntime = nil
        XCTAssertNoThrow(try changed.validate())
        XCTAssertThrowsError(try PayloadNativeCode.validateFramework(changed, directory: parent, validate: { _ in }))
        XCTAssertNoThrow(try PayloadNativeCode.validateFramework(manifest, directory: parent, validate: { _ in }))
        changed = manifest
        changed.sharedRuntime?.runtimeVersion = "fs1-other"
        XCTAssertThrowsError(try PayloadNativeCode.validateFramework(changed, directory: parent, validate: { _ in }))
    }

    func testLegacyHandshakeAndFHPayloadRemainCompatible() throws {
        let (manifest, _) = try fixture()
        let data = try JSONEncoder().encode(host)
        XCTAssertNil(try JSONDecoder().decode(PayloadCapabilities.self, from: data).sharedRuntime)
        XCTAssertEqual(manifest.schema, 1)
        var supported = host
        supported.sharedRuntime = sharedIdentity
        XCTAssertNoThrow(try manifest.compatible(with: host))
        XCTAssertNoThrow(try manifest.compatible(with: supported))
    }

    func testSharedPayloadUsesExistingArchiveAndStore() async throws {
        let (manifest, parent) = try sharedFixture()
        var supported = host
        supported.sharedRuntime = sharedIdentity
        let docs = root.appendingPathComponent("shared-documents")
        let store = try PayloadStore(documents: docs, host: supported, validator: { _ in })
        try deliver(manifest, parent, docs: docs)
        let receipts = try await store.processInbox()
        XCTAssertEqual(receipts.map(\.state), [.active])
        let installed = docs.appendingPathComponent(PayloadStore.bundlesName)
            .appendingPathComponent(manifest.titleID).appendingPathComponent(manifest.generation)
            .appendingPathComponent(manifest.framework)
        try await store.prepareLaunch(titleID: manifest.titleID, framework: installed)
        let (replacement, replacementParent) = try sharedFixture()
        try deliver(replacement, replacementParent, docs: docs)
        let update = try await store.processInbox()
        XCTAssertEqual(update.map(\.state), [.restartRequired])
    }

    func testSharedPayloadRejectedByHostWithoutRuntime() async throws {
        let (manifest, parent) = try sharedFixture()
        let docs = root.appendingPathComponent("legacy-documents")
        let store = try PayloadStore(documents: docs, host: host, validator: { _ in })
        try deliver(manifest, parent, docs: docs)
        let receipts = try await store.processInbox()
        XCTAssertEqual(receipts.map(\.state), [.rejected])
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent(PayloadStore.bundlesName)
            .appendingPathComponent(manifest.titleID).path))
    }
}
