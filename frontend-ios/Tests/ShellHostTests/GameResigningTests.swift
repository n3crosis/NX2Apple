import Foundation
import Testing
import ShellUI
@testable import ShellHost

@Suite struct GameResigningTests {
    private func fixture(_ box: FrameworkBox, folder: String = "DmGame\(Fixtures.orbit).framework") throws -> URL {
        let framework = try box.makeFramework(folder: folder)
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleExecutable": "DmGame",
            "CFBundleIdentifier": "org.test.game"
        ], format: .xml, options: 0)
        try info.write(to: framework.appendingPathComponent("Info.plist"))
        // Synthetic Mach-O and CodeDirectory metadata, not a loadable game or trusted signature.
        var bytes = Data()
        for word in [UInt32(0xfeedfacf), 0x0100000c, 0, 6, 1, 16, 0, 0, 0x1d, 16, 64, 128] {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        bytes.append(Data(repeating: 0, count: 16))
        for word in [UInt32(0xfade0cc0), 64, 1, 0, 20,
                     0xfade0c02, 44, 0x20000, 0, 0, 0, 0, 0, 64, 0, 0] {
            var big = word.bigEndian
            withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
        }
        bytes.append(Data(repeating: 0, count: 64))
        bytes.append(Data("tail".utf8))
        try bytes.write(to: framework.appendingPathComponent("DmGame"))
        return framework
    }

    @Test func failureLeavesOriginalAndRemovesStage() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let executable = framework.appendingPathComponent("DmGame")
        let original = try Data(contentsOf: executable)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { copy in
                try Data("changed copy".utf8).write(to: copy.appendingPathComponent("DmGame"))
                throw ShellSigningError.signature("test failure")
            }
        }
        #expect(try Data(contentsOf: executable) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
    }

    @Test func successAtomicallyReplacesOriginalAndCanRepeat() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let executable = framework.appendingPathComponent("DmGame")
        var expected = try Data(contentsOf: executable)
        for marker in [UInt8(1), 2] {
            expected[191] = marker
            let before = try GameSigningFileIdentity(file: executable)
            let receipt = try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { copy in
                #expect(copy != framework)
                try expected.write(to: copy.appendingPathComponent("DmGame"))
            }
            #expect(receipt.titleID == Fixtures.orbit)
            // Directory enumeration may return /private/var for a /var temporary URL.
            #expect(receipt.executable.standardizedFileURL == executable.standardizedFileURL)
            #expect(receipt.previousModificationSeconds == before.modificationSeconds)
            #expect(receipt.installedFile == (try GameSigningFileIdentity(file: executable)))
            #expect(receipt.installedFile.inode != before.inode)
            #expect(try Data(contentsOf: executable) == expected)
            #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
        }
    }

    @Test func noncanonicalImportedFrameworkKeepsItsName() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box, folder: "OrbitImported.framework")
        #expect(GameCatalogue.readFramework(at: framework).problem == nil)
        #expect(GameResigning.isEligible(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit))
        var signed = try Data(contentsOf: framework.appendingPathComponent("DmGame"))
        signed[191] = 1
        try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { copy in
            #expect(copy.lastPathComponent == framework.lastPathComponent)
            #expect(copy != framework)
            try signed.write(to: copy.appendingPathComponent("DmGame"))
        }
        #expect(try Data(contentsOf: framework.appendingPathComponent("DmGame")) == signed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == ["OrbitImported.framework"])
    }

    @Test func eligibilityDoesNotExpandOutsideImportedFrameworks() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box, folder: "OrbitImported.framework")
        #expect(!GameResigning.isEligible(framework: framework, hotRoot: box.documents, titleID: Fixtures.orbit))
        #expect(!GameResigning.isEligible(framework: framework, hotRoot: box.frameworks, titleID: "invalid"))
        #expect(!GameResigning.isEligible(framework: box.frameworks.appendingPathComponent("OrbitImported.bundle"), hotRoot: box.frameworks, titleID: Fixtures.orbit))
        let nested = box.frameworks.appendingPathComponent("nested/OrbitImported.framework")
        #expect(!GameResigning.isEligible(framework: nested, hotRoot: box.frameworks, titleID: Fixtures.orbit))
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.documents, titleID: Fixtures.orbit) { _ in
                Issue.record("Must not sign a framework outside the configured import root")
            }
        }
    }

    @Test func linkedFrameworkContentsAreRejected() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        try FileManager.default.createSymbolicLink(at: framework.appendingPathComponent("link"), withDestinationURL: box.root)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                Issue.record("Must not sign linked files")
            }
        }
    }

    @Test func changedSourceIsNotOverwrittenOrDeleted() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let movedOriginal = box.root.appendingPathComponent("original.framework")
        let marker = framework.appendingPathComponent("external-import")
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                try FileManager.default.moveItem(at: framework, to: movedOriginal)
                try FileManager.default.copyItem(at: movedOriginal, to: framework)
                try Data("new external import".utf8).write(to: marker)
            }
        }
        #expect(try Data(contentsOf: marker) == Data("new external import".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
    }

    @Test func sourceChangedToSymlinkIsNotExchanged() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let movedOriginal = box.root.appendingPathComponent("original.framework")
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                try FileManager.default.moveItem(at: framework, to: movedOriginal)
                try FileManager.default.createSymbolicLink(at: framework, withDestinationURL: movedOriginal)
            }
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: framework.path) == movedOriginal.path)
        #expect(FileManager.default.fileExists(atPath: movedOriginal.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
    }

    @MainActor @Test func cloudPromptReservesAllWindowsUntilCancelled() throws {
        let box = try Sandbox()
        let firstSettings = ShellSettingsStore(defaults: UserDefaults(suiteName: "signing-first-\(UUID().uuidString)")!)
        let secondSettings = ShellSettingsStore(defaults: UserDefaults(suiteName: "signing-second-\(UUID().uuidString)")!)
        let first = ShellHostModel(config: box.config(), shellSettings: firstSettings)
        let second = ShellHostModel(config: box.config(), shellSettings: secondSettings)
        // Isolate the session assertion from other tests' launch reservations.
        let session = GameSigningSession()
        session.register(first)
        session.register(second)
        #expect(!session.hasPendingLaunch)
        second.cloudConflict = CloudSavePrompt(gameID: Fixtures.orbit, gameTitle: "Orbit")
        #expect(session.hasPendingLaunch)
        second.cancelCloudConflict()
        #expect(!session.hasPendingLaunch)
    }


    @Test func hardLinkedSourceIsRejectedBeforeSigning() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let executable = framework.appendingPathComponent("DmGame")
        let outsideLink = box.root.appendingPathComponent("linked-image")
        try FileManager.default.linkItem(at: executable, to: outsideLink)
        let original = try Data(contentsOf: executable)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                Issue.record("Must not sign hard-linked source files")
            }
        }
        #expect(try Data(contentsOf: outsideLink) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
    }

    @Test func nonSignatureChangesNeverReplaceTheInstalledImage() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let executable = framework.appendingPathComponent("DmGame")
        let original = try Data(contentsOf: executable)
        // Header, signature command, code/data and bytes after the reservation.
        for offset in [0, 40, 44, 50, 193, original.count] {
            #expect(throws: ShellSigningError.self) {
                try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { copy in
                    var changed = original
                    if offset == changed.count { changed.append(1) }
                    else { changed[offset] ^= 1 }
                    try changed.write(to: copy.appendingPathComponent("DmGame"))
                }
            }
            #expect(try Data(contentsOf: executable) == original)
        }
    }

    @Test func inPlaceSourceChangeDuringSigningIsRejected() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let executable = framework.appendingPathComponent("DmGame")
        let original = try Data(contentsOf: executable)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                // Even a signature-only external change invalidates this operation's source identity.
                var changed = original
                changed[191] = 2
                try changed.write(to: executable)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)],
                                                      ofItemAtPath: executable.path)
            }
        }
        #expect(try Data(contentsOf: executable)[191] == 2)
    }

    @MainActor @Test func runningGameReservesAllWindowsAndReturnReleasesThem() throws {
        let box = try Sandbox()
        let launcher = SigningLifecycleLauncher()
        let first = ShellHostModel(config: box.config(), launcher: launcher)
        let second = ShellHostModel(config: box.config())
        let session = GameSigningSession()
        session.register(first)
        session.register(second)
        #expect(!session.hasPendingLaunch)
        launcher.isGameRunning = true
        #expect(session.hasPendingLaunch)
        // Native state remains true during teardown and becomes false only on return.
        #expect(first.isGameRunning)
        launcher.isGameRunning = false
        #expect(!session.hasPendingLaunch)
        launcher.isGameRunning = true
        #expect(session.hasPendingLaunch)
        launcher.isGameRunning = false
        #expect(!session.hasPendingLaunch)
    }

    @Test func interruptedStagesAreCleanedWithoutRemovingUnrelatedFolders() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let stale = box.frameworks.appendingPathComponent(".resigning-" + Fixtures.orbit + "-" + UUID().uuidString)
        let unrelated = box.frameworks.appendingPathComponent(".resigning-user-files")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                throw ShellSigningError.signature("test failure")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path)) == Set([framework.lastPathComponent, unrelated.lastPathComponent]))
    }

}

@MainActor private final class SigningLifecycleLauncher: GameLauncher {
    var isGameRunning = false
    func launch(_ game: LaunchableGame) async throws { isGameRunning = true }
}
