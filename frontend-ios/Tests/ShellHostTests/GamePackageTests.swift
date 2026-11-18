import Foundation
import Testing
import Security
@testable import ShellHost

@Suite struct GamePackageTests {
    @MainActor @Test func externalOpensWaitForExistingImportReview() async throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config())
        let archive = try #require(Bundle.module.url(forResource: "Package", withExtension: "nxb", subdirectory: "Fixtures"))
        await model.preparePackage(archive)
        let current = try #require(model.packagePreview)
        model.enqueueExternalPackage(archive)
        await model.prepareNextExternalPackage()
        #expect(model.hasExternalPackage)
        #expect(model.packagePreview?.id == current.id)
        #expect(FileManager.default.fileExists(atPath: current.directory.path))
        model.cancelPackageImport()
        model.importingSigningIdentity = true
        await model.prepareNextExternalPackage()
        #expect(model.hasExternalPackage)
        #expect(model.packagePreview == nil)
        model.importingSigningIdentity = false
        await model.prepareNextExternalPackage()
        #expect(!model.hasExternalPackage)
        #expect(model.packagePreview != nil)
        #expect(model.packages.isEmpty, "External open only previews, never accepts or installs")
        model.cancelPackageImport()
    }

    @MainActor @Test func failedBuildInstallKeepsArchiveWithoutOpeningImportReview() async throws {
        let box = try Sandbox()
        let config = box.config()
        let model = ShellHostModel(config: config)
        let archive = try #require(Bundle.module.url(forResource: "Package", withExtension: "nxb", subdirectory: "Fixtures"))
        let original = try Data(contentsOf: archive)
        await #expect(throws: (any Error).self) { try await model.installBuiltPackage(archive) }
        #expect(try Data(contentsOf: archive) == original)
        #expect(model.packagePreview == nil)
        #expect(model.packages.isEmpty)
        #expect(!model.importingPackage)
        let imports = config.appDataRoot.deletingLastPathComponent().appendingPathComponent("NXB")
        #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
    }

    @Test func signedExportPreservesOriginalAndChecksPayloadBytes() async throws {
        let source = try #require(Bundle.module.url(forResource: "Package", withExtension: "nxb", subdirectory: "Fixtures"))
        let original = try Data(contentsOf: source)
        let proofURL = try #require(Bundle.module.url(forResource: "RS256", withExtension: "json", subdirectory: "Fixtures"))
        let proof = try Data(contentsOf: proofURL)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("signed.nxb")
        try GamePackage.exportSigned(source, to: output, signManifest: { _ in proof })
        #expect(try Data(contentsOf: source) == original)
        let result = try GamePackage.stage(output, in: folder, allowUnsigned: false,
            verifyPublisher: { try GamePackageSignature.verify(manifest: $0, proof: $1) },
            allowUnknownPublisher: true, checkCompatibility: { _ in })
        #expect(result.publisher?.trusted == false)
        let reader = try NXBArchive.Reader(source)
        defer { try? reader.input.close() }
        let entry = try #require(reader.entries["run/nxgame.dylib"])
        var broken = original
        broken[Int(entry.start)] ^= 1
        let corrupt = folder.appendingPathComponent("corrupt.nxb")
        try broken.write(to: corrupt)
        let rejected = folder.appendingPathComponent("rejected.nxb")
        #expect(throws: (any Error).self) {
            try GamePackage.exportSigned(corrupt, to: rejected, signManifest: { _ in proof })
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
        let cancelled = folder.appendingPathComponent("cancelled.nxb")
        let export = Task.detached {
            try GamePackage.exportSigned(source, to: cancelled) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return proof
            }
        }
        do {
            try await export.value
            Issue.record("Cancelled export completed")
        } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .allSatisfy { !$0.hasPrefix(".nxb-export-") })
    }

    @Test func verifiesPersonalCertificatesWithoutTreatingThemAsTrusted() throws {
        let archive = try #require(Bundle.module.url(forResource: "Package", withExtension: "nxb", subdirectory: "Fixtures"))
        let reader = try NXBArchive.Reader(archive)
        defer { try? reader.input.close() }
        let entry = try #require(reader.entries["nxb.json"])
        let manifest = try reader.read(entry.start, Int(entry.bytes))
        for algorithm in ["ES256", "RS256"] {
            let url = try #require(Bundle.module.url(forResource: algorithm, withExtension: "json", subdirectory: "Fixtures"))
            let proof = try Data(contentsOf: url)
            // Public, self-signed fixtures expired in 2020, verified independently
            // using Python cryptography; no test or user private keys are stored here.
            let publisher = try GamePackageSignature.verify(manifest: manifest, proof: proof)
            #expect(!publisher.trusted)
            #expect(publisher.subject?.isEmpty == false)
            #expect(publisher.expiresAt == Date(timeIntervalSince1970: 1_577_923_200))
            if algorithm == "ES256" {
                var legacy = try #require(JSONSerialization.jsonObject(with: proof) as? [String: Any])
                let encoded = try #require(legacy.removeValue(forKey: "certificate") as? String)
                let der = try #require(Data(base64Encoded: encoded))
                let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
                let key = try #require(SecCertificateCopyKey(certificate))
                let raw = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
                let legacyProof = try JSONSerialization.data(withJSONObject: legacy)
                #expect(try GamePackageSignature.verify(manifest: manifest, proof: legacyProof,
                    pinnedKeys: [publisher.keyID: raw]).trusted)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: folder) }
                let legacyArchive = folder.appendingPathComponent("legacy.nxb")
                #expect(FileManager.default.createFile(atPath: legacyArchive.path, contents: nil))
                let files = try JSONDecoder().decode(GamePackageManifest.self, from: manifest).files
                try NXBArchive.write(legacyArchive, reader: reader, files: files, manifest: manifest, proof: legacyProof)
                let exported = folder.appendingPathComponent("exported.nxb")
                try GamePackage.exportSigned(legacyArchive, to: exported, verifyPublisher: {
                    try GamePackageSignature.verify(manifest: $0, proof: $1, pinnedKeys: [publisher.keyID: raw])
                }, signManifest: { _ in proof })
                #expect(try GamePackage.inspect(exported, verifyPublisher: {
                    try GamePackageSignature.verify(manifest: $0, proof: $1)
                }).publisher?.certificateSHA256 == publisher.certificateSHA256)
            }

            var substituted = try #require(JSONSerialization.jsonObject(with: proof) as? [String: Any])
            let encoded = try #require(substituted["certificate"] as? String)
            var changedCertificate = try #require(Data(base64Encoded: encoded))
            let subjectRange = try #require(changedCertificate.range(of: Data("NXB Fixture".utf8)))
            changedCertificate.replaceSubrange(subjectRange, with: Data("NXB Altered".utf8))
            substituted["certificate"] = changedCertificate.base64EncodedString()
            let changedProof = try JSONSerialization.data(withJSONObject: substituted)
            #expect(throws: GamePackageError.self) {
                _ = try GamePackageSignature.verify(manifest: manifest, proof: changedProof)
            }

            let fingerprint = try #require(publisher.certificateSHA256)
            #expect(try GamePackageSignature.verify(manifest: manifest, proof: proof,
                trustedCertificates: [fingerprint]).trusted)
            #expect(throws: GamePackageError.self) {
                _ = try GamePackageSignature.verify(manifest: manifest + Data([32]), proof: proof)
            }
        }
    }

    /// Produced by nxb_build::package::write, not a second Swift ZIP implementation.
    @Test func stagesProducerPackageAndRejectsTampering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let signed = try #require(Bundle.module.url(forResource: "SignedPackage", withExtension: "nxb", subdirectory: "Fixtures"))
        let verify: GamePackage.VerifyPublisher = { try GamePackageSignature.verify(manifest: $0, proof: $1) }
        let preview = try GamePackage.inspect(signed, verifyPublisher: verify)
        #expect(preview.manifest.name == "Fixture")
        #expect(preview.publisher?.trusted == false)
        #expect(preview.manifestSHA256.count == 64)
        #expect(preview.cover == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(throws: GamePackageError.self) {
            _ = try GamePackage.stage(signed, in: root, allowUnsigned: true, verifyPublisher: verify) { _ in }
        }
        let approved = try GamePackage.stage(signed, in: root, allowUnsigned: false,
            verifyPublisher: verify, allowUnknownPublisher: true) { _ in }
        #expect(approved.publisher?.trusted == false)
        let source = try #require(Bundle.module.url(forResource: "Package", withExtension: "nxb", subdirectory: "Fixtures"))
        let archive = root.appendingPathComponent("Fixture.nxb")
        try FileManager.default.copyItem(at: source, to: archive)
        #expect(throws: GamePackageError.self) {
            _ = try GamePackage.stage(archive, in: root, allowUnsigned: false) { _ in }
        }
        let staged = try GamePackage.stage(archive, in: root, allowUnsigned: true) { value in
            #expect(value.runtimeABI == 1)
            #expect(value.runtimeRevision == String(repeating: "a", count: 40))
        }
        #expect(staged.manifest.name == "Fixture")
        #expect(try Data(contentsOf: staged.directory.appendingPathComponent("run/nxgame.dylib")) == Data(repeating: 0, count: 32))
        let reader = try NXBArchive.Reader(archive)
        let entry = try #require(reader.entries["run/nxgame.dylib"])
        try reader.input.close()
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seek(toOffset: entry.start)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(throws: GamePackageError.self) {
            _ = try GamePackage.stage(archive, in: root, allowUnsigned: true) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == before)
        var invalid = staged.manifest
        invalid.files[0].path = "run/../escape"
        #expect(throws: GamePackageError.self) { try invalid.validate() }
    }
    @Test func installationPreservesOriginalAndActivatesOnlyAfterSigning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(Bundle.module.url(forResource: "Package", withExtension: "nxb", subdirectory: "Fixtures"))
        let library = GamePackageLibrary(root: root)
        let prepared = try library.prepare(source)
        let installed = try library.install(prepared, checkCompatibility: { _ in }) { executable in
            try Data([1, 2, 3]).write(to: executable)
        }
        #expect(!FileManager.default.fileExists(atPath: installed.archive.path))
        #expect(try Data(contentsOf: installed.directory.appendingPathComponent("original.dylib")) == Data(repeating: 0, count: 32))
        #expect(try Data(contentsOf: installed.runRoot.appendingPathComponent("nxgame.dylib")) == Data([1, 2, 3]))
        // A streamed export authenticates the original code, not the local signature.
        let output = root.appendingPathComponent("streamed.nxb")
        #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        try GamePackage.streamDirectory(installed.directory) { try handle.write(contentsOf: $0) }
        try handle.close()
        let roundTrip = try GamePackage.stage(output, in: root, allowUnsigned: true) { _ in }
        defer { try? FileManager.default.removeItem(at: roundTrip.directory) }
        #expect(try Data(contentsOf: roundTrip.directory.appendingPathComponent("run/nxgame.dylib")) == Data(repeating: 0, count: 32))
        #expect(library.entries().map(\.directory) == [installed.directory])
        let isolated = try library.prepare(installed)
        let activeData = installed.runRoot.appendingPathComponent("game.json")
        let before = try Data(contentsOf: activeData)
        try Data("changed".utf8).write(to: isolated.directory.appendingPathComponent("run/game.json"))
        #expect(try Data(contentsOf: activeData) == before)
        #expect(throws: GamePackageError.self) {
            _ = try library.install(isolated, checkCompatibility: { _ in }, sign: { _ in })
        }
        library.discard(isolated)
        let replacement = try library.prepare(source)
        defer { library.discard(replacement) }
        #expect(throws: GamePackageError.self) {
            _ = try library.install(replacement, checkCompatibility: { _ in }) { _ in
                throw GamePackageError.invalid("signer failed")
            }
        }
        #expect(library.entries().map(\.directory) == [installed.directory])
        let next = try library.install(replacement, checkCompatibility: { _ in }, sign: { _ in })
        try library.prune(preserving: [installed.directory])
        #expect(FileManager.default.fileExists(atPath: installed.directory.path))
        try library.prune(preserving: [])
        #expect(!FileManager.default.fileExists(atPath: installed.directory.path))
        #expect(library.entries().map(\.directory) == [next.directory])
        try library.remove(next, preserving: [next.directory])
        #expect(library.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: next.directory.path))
        try library.prune(preserving: [])
        #expect(!FileManager.default.fileExists(atPath: next.directory.path))
    }

}
