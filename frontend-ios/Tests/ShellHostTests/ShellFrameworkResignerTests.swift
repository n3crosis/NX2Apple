import Foundation
import Testing
@testable import ShellHost

@Suite struct ShellFrameworkResignerTests {
    private func header(magic: UInt32 = 0xfeedfacf, cpu: UInt32 = 0x0100000c,
                        kind: UInt32 = 6) -> Data {
        var bytes = Data()
        for word in [magic, cpu, 0, kind] {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    private var universalHeader: Data {
        // Big-endian FAT_MAGIC, one arm64 architecture and its subtype.
        Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1, 1, 0, 0, 12, 0, 0, 0, 0])
    }

    private func metadata(_ framework: URL, executable: String = "DmGame") throws {
        let info = ["CFBundleExecutable": executable, "CFBundleIdentifier": "org.test.game"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: framework.appendingPathComponent("Info.plist"))
    }

    @Test func signingIdentifierUsesHostWithoutChangingFrameworkMetadata() throws {
        let box = try FrameworkBox()
        let framework = try box.makeFramework()
        try metadata(framework)
        let info = framework.appendingPathComponent("Info.plist")
        let original = try Data(contentsOf: info)
        for host in ["org.test.shell", "org.test.shell.resigned", String(repeating: "a", count: 255)] {
            #expect(try ShellFrameworkResigner.signingIdentifier(framework: framework,
                        hostBundleIdentifier: host) == host)
            #expect(try ShellFrameworkResigner.bundleIdentifier(framework: framework) == "org.test.game")
            #expect(try Data(contentsOf: info) == original)
        }
    }

    @Test func invalidHostIdentifierDoesNotFallBackToFrameworkIdentifier() throws {
        let box = try FrameworkBox()
        let framework = try box.makeFramework()
        try metadata(framework)
        let invalid: [String?] = [nil, "", "org.test.\0shell", String(repeating: "a", count: 256),
                                  String(repeating: "é", count: 128)]
        for host in invalid {
            #expect(throws: ShellSigningError.self) {
                try ShellFrameworkResigner.signingIdentifier(framework: framework,
                                                            hostBundleIdentifier: host)
            }
        }
    }

    @Test func hostIdentifierDoesNotBypassFrameworkMetadataValidation() throws {
        let box = try FrameworkBox()
        let framework = try box.makeFramework()
        for identifier in ["", "org.test.\0game", String(repeating: "a", count: 256)] {
            let info = ["CFBundleExecutable": "DmGame", "CFBundleIdentifier": identifier]
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: framework.appendingPathComponent("Info.plist"))
            #expect(throws: ShellSigningError.self) {
                try ShellFrameworkResigner.signingIdentifier(framework: framework,
                                                            hostBundleIdentifier: "org.test.shell")
            }
        }
    }

    @Test func unsupportedMainCannotHideBehindNestedLibrary() throws {
        let box = try FrameworkBox()
        let framework = try box.makeFramework()
        try metadata(framework)
        let nested = framework.appendingPathComponent("Libraries")
        try box.makeFolder(nested)
        try header().write(to: nested.appendingPathComponent("helper.dylib"))
        // Universal, x86_64, 32-bit, truncated, and ordinary bytes are not a main library.
        for main in [universalHeader, header(cpu: 0x01000007),
                     header(magic: 0xfeedface, cpu: 12), Data([0xcf, 0xfa]), Data("invalid".utf8)] {
            try main.write(to: framework.appendingPathComponent("DmGame"))
            #expect(throws: ShellSigningError.self) {
                try ShellFrameworkResigner.nativeFiles(framework: framework)
            }
        }
    }

    @Test func bundleAndManifestMustSelectTheSameDirectMain() throws {
        let box = try FrameworkBox()
        let framework = try box.makeFramework()
        try header().write(to: framework.appendingPathComponent("DmGame"))
        try header().write(to: framework.appendingPathComponent("Other"))
        for executable in ["Other", "../DmGame", "", "missing"] {
            try metadata(framework, executable: executable)
            #expect(throws: ShellSigningError.self) {
                try ShellFrameworkResigner.nativeFiles(framework: framework)
            }
        }
    }

    @Test func relativeFrameworkURLFindsItsDirectMain() throws {
        let box = try FrameworkBox()
        let framework = try box.makeFramework()
        try metadata(framework)
        try header().write(to: framework.appendingPathComponent("DmGame"))
        let relative = try #require(URL(string: framework.lastPathComponent + "/",
                                        relativeTo: framework.deletingLastPathComponent()))
        let files = try ShellFrameworkResigner.nativeFiles(framework: relative)
        #expect(files.map { $0.standardizedFileURL.path } ==
                [framework.appendingPathComponent("DmGame").standardizedFileURL.path])
    }

    @Test func unsupportedNestedHostCodeIsRejectedButGPUResourcesRemainUntouched() throws {
        let box = try FrameworkBox()
        let framework = try box.makeFramework()
        try metadata(framework)
        let main = framework.appendingPathComponent("DmGame")
        try header().write(to: main)
        let resource = framework.appendingPathComponent("shader-resource")
        // GPU Mach-O file types and Metal containers are resources, not host code.
        // A Java class header shares FAT_MAGIC, followed by version and pool entries.
        let javaClass = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 61, 0, 2, 1, 0, 1, 65])
        for bytes in [header(cpu: 0x01000013, kind: 13), Data("MTLB resource".utf8), javaClass] {
            try bytes.write(to: resource)
            #expect(try ShellFrameworkResigner.nativeFiles(framework: framework).map { $0.standardizedFileURL.path } ==
                    [main.standardizedFileURL.path])
            #expect(try Data(contentsOf: resource) == bytes)
        }
        for bytes in [header(cpu: 0x01000007), universalHeader,
                      header(kind: 2), Data([0xcf, 0xfa, 0xed, 0xfe])] {
            try bytes.write(to: resource)
            #expect(throws: ShellSigningError.self) {
                try ShellFrameworkResigner.nativeFiles(framework: framework)
            }
        }
    }
}
