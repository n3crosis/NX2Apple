import Foundation
import XCTest
@testable import NXCore

final class ShellSharedRuntimeTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func game(_ parent: URL, loader: String = "FS") throws -> String {
        let url = parent.appendingPathComponent("DmGame0100000000000001.framework")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{\"loader\":\"\(loader)\"}".utf8).write(to: url.appendingPathComponent("game.manifest.json"))
        return url.path
    }

    private func runtime(_ parent: URL, marker: String) throws -> String {
        let url = parent.appendingPathComponent("DmSharedRuntime.framework")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("DmSharedRuntime"))
        return url.path
    }

    func testLegacyLibraryDecodesWithoutRuntime() throws {
        let library = try JSONDecoder().decode(ShellLibrary.self, from: Data("{\"bundleID\":\"org.test\",\"team\":\"\",\"games\":[]}".utf8))
        XCTAssertNil(library.sharedRuntime)
    }

    func testMirrorPersistsAfterBuildFolderRemovalAndForwardsEnvironment() throws {
        let base = try fixture(), build = base.appendingPathComponent("build")
        let framework = try game(build)
        _ = try runtime(build, marker: "new")
        let root = base.appendingPathComponent("shell").path
        var library = ShellLibrary(games: [.init(titleID: "0100000000000001", name: "Game", framework: framework)])
        let transaction = try ShellInstall.prepareSharedRuntime(root: root, library: &library, preferredFramework: framework)
        try library.save(root: root)
        transaction?.commit()
        let env = ShellInstall.projectEnvironment(root: root, frameworks: [framework], bundleID: library.bundleID,
            team: "", python: "python3", path: "/bin", home: "/tmp", user: "test")
        XCTAssertEqual(env["DM_SHELL_SHARED_RUNTIME"], ShellInstall.mirroredSharedRuntime(root: root))
        try FileManager.default.removeItem(at: build)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(ShellLibrary.load(root: root).sharedRuntime) + "/DmSharedRuntime"))
    }

    func testReplacementRollbackRestoresPreviousRuntime() throws {
        let base = try fixture(), build = base.appendingPathComponent("build")
        let framework = try game(build)
        _ = try runtime(build, marker: "new")
        let root = base.appendingPathComponent("shell").path
        _ = try runtime(URL(fileURLWithPath: ShellInstall.frameworksMirror(root: root)), marker: "old")
        var library = ShellLibrary(games: [.init(titleID: "0100000000000001", name: "Game", framework: framework)])
        let transaction = try ShellInstall.prepareSharedRuntime(root: root, library: &library, preferredFramework: framework)
        transaction?.rollback()
        XCTAssertEqual(try String(contentsOfFile: ShellInstall.mirroredSharedRuntime(root: root) + "/DmSharedRuntime", encoding: .utf8), "old")
    }

    func testNewMirrorRollbackRemovesUncommittedRuntime() throws {
        let base = try fixture(), framework = try game(base)
        _ = try runtime(base, marker: "new")
        let root = base.appendingPathComponent("shell").path
        var library = ShellLibrary(games: [.init(titleID: "1", name: "Game", framework: framework)])
        let transaction = try ShellInstall.prepareSharedRuntime(root: root, library: &library, preferredFramework: framework)
        transaction?.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShellInstall.mirroredSharedRuntime(root: root)))
    }

    func testLegacyGameDoesNotSelectStaleSiblingRuntime() throws {
        let base = try fixture(), framework = try game(base, loader: "FH")
        _ = try runtime(base, marker: "stale")
        var library = ShellLibrary(games: [.init(titleID: "1", name: "Game", framework: framework)])
        XCTAssertNil(try ShellInstall.prepareSharedRuntime(root: base.path + "/shell", library: &library, preferredFramework: framework))
        XCTAssertNil(library.sharedRuntime)
    }

    func testSharedGameRequiresRuntime() throws {
        let base = try fixture(), framework = try game(base)
        var library = ShellLibrary(games: [.init(titleID: "1", name: "Game", framework: framework)])
        XCTAssertThrowsError(try ShellInstall.prepareSharedRuntime(root: base.path + "/shell", library: &library, preferredFramework: framework))
    }
}
