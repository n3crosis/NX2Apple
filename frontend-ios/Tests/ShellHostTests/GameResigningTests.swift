import Foundation
import Testing
@testable import ShellHost

@Suite struct GameResigningTests {
    private func fixture(_ box: FrameworkBox) throws -> URL {
        let framework = try box.makeFramework(folder: "DmGame\(Fixtures.orbit).framework")
        // Header selection fixture, not a loadable or signed game.
        var bytes = Data()
        for word in [UInt32(0xfeedfacf), 0x0100000c, 0, 6] {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
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

    @Test func successAtomicallyReplacesOriginal() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { copy in
            #expect(copy != framework)

            try Data("signed copy".utf8).write(to: copy.appendingPathComponent("DmGame"))
        }
        #expect(try Data(contentsOf: framework.appendingPathComponent("DmGame")) == Data("signed copy".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
    }

    @Test func embeddedFrameworkAndLinksAreRejected() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.documents, titleID: Fixtures.orbit) { _ in
                Issue.record("Must not sign embedded files")
            }
        }
        try FileManager.default.createSymbolicLink(at: framework.appendingPathComponent("link"), withDestinationURL: box.root)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                Issue.record("Must not sign linked files")
            }
        }
    }
}
