import Foundation
import CryptoKit

/// Distinct nxkit transport contract. Never interpreted as an FH framework.
public struct GamePackageManifest: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var path: String
        public var bytes: UInt64
        public var sha256: String
        public var executable: Bool
    }

    public static let fileName = "nxb.json"
    public var schema = 2
    public var runtime = "nxkit"
    public var runtimeABI = 1
    public var runtimeRevision: String
    public var platform = "ios"
    public var architecture = "arm64"
    public var generation: String
    public var titleID: String
    public var name: String
    public var minOS: String
    public var files: [File]

    public init(generation: String = UUID().uuidString.lowercased(), titleID: String, name: String,
                minOS: String, runtimeRevision: String, runtimeABI: Int, files: [File]) {
        self.generation = generation; self.titleID = titleID; self.name = name
        self.minOS = minOS; self.files = files
        self.runtimeRevision = runtimeRevision; self.runtimeABI = runtimeABI
    }

    /// Structural package validation only. Each consumer separately checks its
    /// supported runtime profile before installing and launching this package.
    public func validate() throws {
        guard schema == 2, runtime == "nxkit", runtimeABI > 0,
              runtimeRevision.utf8.count == 40,
              runtimeRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              platform == "ios", architecture == "arm64", UUID(uuidString: generation) != nil,
              generation == generation.lowercased(), titleID.utf8.count == 16,
              titleID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              !name.isEmpty, name.utf8.count <= 4096, !name.contains("\0"),
              Self.version(minOS) != nil, !files.isEmpty, files.count <= 65_533 else {
            throw GamePackageError.invalid("nxkit manifest fields")
        }
        var paths = Set<String>()
        var total: UInt64 = 0
        for file in files {
            guard Self.safePath(file.path), file.path.hasPrefix("run/"),
                  file.path == file.path.precomposedStringWithCanonicalMapping,
                  paths.insert(file.path.lowercased()).inserted,
                  file.sha256.utf8.count == 64,
                  file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  file.bytes <= NXBArchive.maximumBytes, total <= NXBArchive.maximumBytes - file.bytes,
                  !file.executable || file.path == "run/nxgame.dylib" else {
                throw GamePackageError.invalid("nxkit file inventory")
            }
            total += file.bytes
        }
        for path in paths {
            let parts = path.split(separator: "/")
            for n in 1..<parts.count where paths.contains(parts.prefix(n).joined(separator: "/")) {
                throw GamePackageError.invalid("nxkit file is also a directory")
            }
        }
        guard files.contains(where: { $0.path == "run/game.json" && $0.bytes > 0 && $0.bytes <= NXBArchive.metadataLimit }),
              files.contains(where: { $0.path == "run/nxgame.dylib" && $0.executable && $0.bytes >= 32 && $0.bytes <= 1 << 30 }) else {
            throw GamePackageError.invalid("nxkit required files")
        }
    }

    public static func safeComponent(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".." && text.utf8.count < 256 &&
        !text.contains("/") && !text.contains("\\") && !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    public static func safePath(_ text: String) -> Bool {
        text.utf8.count < 4096 && text.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { safeComponent(String($0)) }
    }

    public static func version(_ text: String) -> Int? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ (0..<1000).contains($0) }) else { return nil }
        return numbers[0] * 1_000_000 + (numbers.count > 1 ? numbers[1] * 1000 : 0) + (numbers.count > 2 ? numbers[2] : 0)
    }
}

public enum GamePackageError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): "Game package: \(reason)" }
    }
}

/// Transport only: stages a verified run directory, without signing, activation,
/// catalogue changes or a claim that its runtime is available on this device.
/// Retain the original archive for sharing: locally signing staged code changes
/// its hashes and must not be represented as the publisher-signed package.
public enum GamePackage {
    /// Verifies the original manifest bytes, never a JSON re-encoding.
    /// Valid-but-unknown publishers remain rejected unless explicitly approved.
    public typealias VerifyPublisher = (_ manifest: Data, _ proof: Data) throws -> GamePackagePublisher

    public struct Preview: Sendable {
        public let manifest: GamePackageManifest
        public let publisher: GamePackagePublisher?
        public let cover: Data?
        public let manifestSHA256: String
    }

    /// Inspect for owner review only. No files are staged and no publisher trust
    /// decision is made. Stage still checks approval and verifies every file.
    public static func inspect(_ archive: URL, verifyPublisher: VerifyPublisher? = nil) throws -> Preview {
        let reader = try NXBArchive.Reader(archive)
        defer { try? reader.input.close() }
        let (manifest, rawManifest, publisher) = try metadata(reader, verifyPublisher: verifyPublisher)
        var cover: Data?
        if let file = manifest.files.first(where: { $0.path == "run/icon.jpg" }), file.bytes <= 4 << 20 {
            let entry = reader.entries[file.path]!
            let data = try reader.read(entry.start, Int(entry.bytes))
            guard NXBArchive.checksum(data) == entry.crc,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw GamePackageError.invalid("cover checksum mismatch")
            }
            cover = data
        }
        return Preview(manifest: manifest, publisher: publisher, cover: cover,
                       manifestSHA256: SHA256.hash(data: rawManifest).map { String(format: "%02x", $0) }.joined())
    }

    private static func metadata(_ reader: NXBArchive.Reader, verifyPublisher: VerifyPublisher?) throws
        -> (GamePackageManifest, Data, GamePackagePublisher?) {
        func metadata(_ name: String, limit: Int) throws -> Data {
            guard let entry = reader.entries[name], entry.bytes > 0, entry.bytes <= UInt64(limit) else {
                throw GamePackageError.invalid("missing or oversized \(name)")
            }
            let bytes = try reader.read(entry.start, Int(entry.bytes))
            guard NXBArchive.checksum(bytes) == entry.crc else {
                throw GamePackageError.invalid("metadata checksum")
            }
            return bytes
        }
        let rawManifest = try metadata(GamePackageManifest.fileName, limit: NXBArchive.metadataLimit)
        let signatureName = "nxb.signature.json"
        let signed = reader.entries[signatureName] != nil
        var publisher: GamePackagePublisher?
        if signed {
            guard let verifyPublisher else { throw GamePackageError.invalid("publisher verification unavailable") }
            let verified = try verifyPublisher(rawManifest, metadata(signatureName, limit: 64 << 10))
            publisher = verified
        }
        let manifest = try JSONDecoder().decode(GamePackageManifest.self, from: rawManifest)
        try manifest.validate()
        guard reader.entries.count == manifest.files.count + (signed ? 2 : 1),
              manifest.files.allSatisfy({ reader.entries[$0.path]?.bytes == $0.bytes }) else {
            throw GamePackageError.invalid("file inventory mismatch")
        }
        return (manifest, rawManifest, publisher)
    }

    /// Explicitly attest to an export copy using the owner's publisher identity.
    /// Existing transport bytes and local executable signatures are never changed.
    public static func exportSigned(_ archive: URL, to output: URL,
                                    verifyPublisher: @escaping VerifyPublisher = {
                                        try GamePackageSignature.verify(manifest: $0, proof: $1)
                                    },
                                    signManifest: (Data) throws -> Data) throws {
        let reader = try NXBArchive.Reader(archive)
        defer { try? reader.input.close() }
        let (manifest, raw, _) = try metadata(reader, verifyPublisher: verifyPublisher)
        let proof = try signManifest(raw)
        _ = try GamePackageSignature.verify(manifest: raw, proof: proof)
        let fm = FileManager.default
        // Publish only a complete copy. Never replace an existing export or source.
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".nxb-export-" + UUID().uuidString)
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw GamePackageError.invalid("cannot create export")
        }
        defer { try? fm.removeItem(at: temporary) }
        try NXBArchive.write(temporary, reader: reader, files: manifest.files, manifest: raw, proof: proof)
        try fm.moveItem(at: temporary, to: output)
    }

    public static func stage(_ archive: URL, in parent: URL, allowUnsigned: Bool,
                             verifyPublisher: VerifyPublisher? = nil, allowUnknownPublisher: Bool = false,
                             checkCompatibility: (GamePackageManifest) throws -> Void) throws
        -> (manifest: GamePackageManifest, directory: URL, publisher: GamePackagePublisher?) {
        let reader = try NXBArchive.Reader(archive)
        defer { try? reader.input.close() }
        let (manifest, rawManifest, publisher) = try metadata(reader, verifyPublisher: verifyPublisher)
        if let publisher {
            guard publisher.trusted || allowUnknownPublisher else {
                throw GamePackageError.invalid("publisher is not trusted")
            }
        } else if !allowUnsigned {
            throw GamePackageError.invalid("unsigned package not allowed")
        }
        try checkCompatibility(manifest)
        let fm = FileManager.default
        guard try fm.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw GamePackageError.invalid("staging parent must be a directory")
        }
        let directory = parent.appendingPathComponent(".nxb-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? fm.removeItem(at: directory) } }
        for file in manifest.files {
            try Task.checkCancellation()
            let entry = reader.entries[file.path]!
            let url = directory.appendingPathComponent(file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw GamePackageError.invalid("cannot create staged file")
            }
            let output = try FileHandle(forWritingTo: url)
            do {
                var remaining = entry.bytes, position = entry.start
                var hash = SHA256()
                var crc: UInt32 = 0xffffffff
                while remaining > 0 {
                    try Task.checkCancellation()
                    let bytes = try reader.read(position, Int(min(remaining, UInt64(NXBArchive.chunk))))
                    hash.update(data: bytes)
                    crc = NXBArchive.updateCRC(crc, bytes)
                    try output.write(contentsOf: bytes)
                    remaining -= UInt64(bytes.count); position += UInt64(bytes.count)
                }
                try output.close()
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256,
                      crc ^ 0xffffffff == entry.crc else {
                    throw GamePackageError.invalid("file checksum mismatch")
                }
                try fm.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            } catch { try? output.close(); throw error }
        }
        let gameData = try Data(contentsOf: directory.appendingPathComponent("run/game.json"))
        guard let game = try JSONSerialization.jsonObject(with: gameData) as? [String: Any],
              game["title_id"] as? String == manifest.titleID,
              game["name"] as? String == manifest.name,
              game["dylib"] as? String == "nxgame.dylib" else {
            throw GamePackageError.invalid("game identity does not match package metadata")
        }
        try rawManifest.write(to: directory.appendingPathComponent(GamePackageManifest.fileName))
        complete = true
        return (manifest, directory, publisher)
    }
}
