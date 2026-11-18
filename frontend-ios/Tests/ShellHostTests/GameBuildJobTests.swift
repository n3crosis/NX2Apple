import XCTest
@testable import ShellHost

final class GameBuildJobTests: XCTestCase {
    func testStaleWindowCannotResumeOrDiscardReplacementJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("game.nsp")
        try Data([1]).write(to: input)
        let work = root.appendingPathComponent("job")
        let first = try GameBuildJob(input: .init(input), updates: [], dlc: [])
        try first.save(in: work)
        XCTAssertTrue(GameBuildJob.isCurrent(id: first.id, exists: true, in: work))
        try GameBuildJob.discard(in: work)
        XCTAssertFalse(GameBuildJob.isCurrent(id: first.id, exists: true, in: work))
        let replacement = try GameBuildJob(input: .init(input), updates: [], dlc: [])
        try replacement.save(in: work)
        XCTAssertFalse(GameBuildJob.isCurrent(id: first.id, exists: true, in: work))
        XCTAssertFalse(GameBuildJob.isCurrent(id: nil, exists: false, in: work))
        XCTAssertTrue(GameBuildJob.isCurrent(id: replacement.id, exists: true, in: work))
    }

    func testJobSurvivesReloadAndUsesCompletedSnapshotWithoutOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("game.nsp")
        try Data([1, 2, 3]).write(to: input)
        let work = root.appendingPathComponent("job")
        let job = try GameBuildJob(input: .init(input), updates: [], dlc: [])
        try job.save(in: work)
        // A resumed job must still reach the source before its first snapshot.
        let pending = try GameBuildJob.load(in: work)
        let resolved = try pending.input.resolve(in: work, slot: "base")
        let scope = resolved.startAccessingSecurityScopedResource()
        defer { if scope { resolved.stopAccessingSecurityScopedResource() } }
        XCTAssertEqual(try Data(contentsOf: resolved), Data([1, 2, 3]))
        let snapshot = work.appendingPathComponent("inputs/base/game.nsp")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: input, to: snapshot)
        try FileManager.default.removeItem(at: input)
        let restored = try GameBuildJob.load(in: work)
        XCTAssertEqual(try restored.input.resolve(in: work, slot: "base"), snapshot)
        XCTAssertEqual(restored.stage, "inputs")
        XCTAssertTrue(GameBuildJob.exists(in: work))
        try GameBuildJob.discard(in: work)
        XCTAssertFalse(GameBuildJob.exists(in: work))
    }
}

final class GameBuildKeysTests: XCTestCase {
    func testKeysSurviveJobDiscardAndCanBeReplacedAndRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("selected.keys")
        let store = GameBuildKeys(directory: root.appendingPathComponent("keys"))
        try Data([1, 2, 3]).write(to: source)
        try store.save(from: source)
        try FileManager.default.removeItem(at: source)
        let reopened = GameBuildKeys(directory: store.directory)
        XCTAssertTrue(reopened.exists)
        XCTAssertEqual(try Data(contentsOf: reopened.url), Data([1, 2, 3]))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: reopened.url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let job = root.appendingPathComponent("job")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try GameBuildJob.discard(in: job)
        XCTAssertTrue(reopened.exists)
        try Data([4]).write(to: source)
        try reopened.save(from: source)
        XCTAssertEqual(try Data(contentsOf: store.url), Data([4]))
        try reopened.remove()
        XCTAssertFalse(store.exists)
    }

    func testInvalidReplacementKeepsSavedKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("selected.keys")
        let store = GameBuildKeys(directory: root.appendingPathComponent("keys"))
        try Data([1]).write(to: source)
        try store.save(from: source)
        for data in [Data(), Data(repeating: 0, count: 1_048_577)] {
            try data.write(to: source)
            XCTAssertThrowsError(try store.save(from: source))
            XCTAssertEqual(try Data(contentsOf: store.url), Data([1]))
        }
        let wrongType = root.appendingPathComponent("game.nsp")
        try Data([2]).write(to: wrongType)
        XCTAssertThrowsError(try store.save(from: wrongType))
    }
}
