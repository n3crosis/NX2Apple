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
              ["ios", "maccatalyst"].contains(platform), architecture == "arm64", UUID(uuidString: generation) != nil,
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
/// Preserve original executable bytes for sharing: locally signing staged code
/// changes its hash, but game data and publisher metadata need only one copy.
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

    /// Read-only full integrity verification. Publisher trust and runtime
    /// compatibility remain caller decisions, just as for inspect().
    public static func verifyArchive(_ archive: URL, verifyPublisher: VerifyPublisher? = nil,
                                     progressBytes: ((UInt64, UInt64) -> Void)? = nil) throws -> Preview {
        try Task.checkCancellation()
        let reader = try NXBArchive.Reader(archive)
        defer { try? reader.input.close() }
        let (manifest, raw, publisher) = try metadata(reader, verifyPublisher: verifyPublisher)
        let total = manifest.files.reduce(UInt64(0)) { $0 + $1.bytes }
        var completed: UInt64 = 0
        var reported: UInt64 = 0
        var gameData = Data()
        var cover: Data?
        progressBytes?(0, total)
        for file in manifest.files {
            let isGame = file.path == "run/game.json"
            let isCover = file.path == "run/icon.jpg" && file.bytes <= 4 << 20
            if isCover { cover = Data() }
            try streamVerifiedFile(file, reader: reader) { bytes in
                if isGame { gameData.append(bytes) }
                if isCover { cover?.append(bytes) }
                completed += UInt64(bytes.count)
                if completed < total && completed - reported >= 8 * 1024 * 1024 {
                    progressBytes?(completed, total)
                    reported = completed
                }
            }
        }
        try validateGameIdentity(gameData, manifest: manifest)
        try Task.checkCancellation()
        progressBytes?(completed, total)
        return Preview(manifest: manifest, publisher: publisher, cover: cover,
                       manifestSHA256: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
    }

    /// Shared by read-only verification and extraction: identical byte bounds,
    /// cancellation points and checksums, with no whole-payload allocation.
    private static func streamVerifiedFile(_ file: GamePackageManifest.File, reader: NXBArchive.Reader,
                                           consume: (Data) throws -> Void) throws {
        try Task.checkCancellation()
        guard let entry = reader.entries[file.path] else { throw GamePackageError.invalid("file inventory mismatch") }
        var remaining = entry.bytes, position = entry.start
        var hash = SHA256()
        var crc: UInt32 = 0xffffffff
        while remaining > 0 {
            try Task.checkCancellation()
            let bytes = try reader.read(position, Int(min(remaining, UInt64(NXBArchive.chunk))))
            hash.update(data: bytes)
            crc = NXBArchive.updateCRC(crc, bytes)
            try consume(bytes)
            remaining -= UInt64(bytes.count)
            position += UInt64(bytes.count)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256,
              crc ^ 0xffffffff == entry.crc else { throw GamePackageError.invalid("file checksum mismatch") }
    }

    private static func validateGameIdentity(_ data: Data, manifest: GamePackageManifest) throws {
        guard let game = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              game["title_id"] as? String == manifest.titleID,
              game["name"] as? String == manifest.name,
              game["dylib"] as? String == "nxgame.dylib" else {
            throw GamePackageError.invalid("game identity does not match package metadata")
        }
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
                                    progress: ((Int, Int) -> Void)? = nil,
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
        try NXBArchive.write(temporary, reader: reader, files: manifest.files, manifest: raw, proof: proof,
                             progress: progress)
        try Task.checkCancellation()
        try fm.moveItem(at: temporary, to: output)
    }

    public static func stage(_ archive: URL, in parent: URL, allowUnsigned: Bool,
                             verifyPublisher: VerifyPublisher? = nil, allowUnknownPublisher: Bool = false,
                             progressBytes: ((UInt64, UInt64) -> Void)? = nil,
                             checkCompatibility: (GamePackageManifest) throws -> Void) throws
        -> (manifest: GamePackageManifest, directory: URL, publisher: GamePackagePublisher?, preview: Preview) {
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
        let total = manifest.files.reduce(UInt64(0)) { $0 + $1.bytes }
        var copied: UInt64 = 0
        var reported: UInt64 = 0
        progressBytes?(0, total)
        for file in manifest.files {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw GamePackageError.invalid("cannot create staged file")
            }
            let output = try FileHandle(forWritingTo: url)
            do {
                try streamVerifiedFile(file, reader: reader) { bytes in
                    try output.write(contentsOf: bytes)
                    copied += UInt64(bytes.count)
                    if copied < total && copied - reported >= 8 * 1024 * 1024 {
                        progressBytes?(copied, total)
                        reported = copied
                    }
                }
                try output.close()
                try fm.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            } catch { try? output.close(); throw error }
        }
        let gameData = try Data(contentsOf: directory.appendingPathComponent("run/game.json"))
        try validateGameIdentity(gameData, manifest: manifest)
        try rawManifest.write(to: directory.appendingPathComponent(GamePackageManifest.fileName))
        if let proof = reader.entries["nxb.signature.json"] {
            try reader.read(proof.start, Int(proof.bytes)).write(to: directory.appendingPathComponent("nxb.signature.json"))
        }
        var cover: Data?
        if let file = manifest.files.first(where: { $0.path == "run/icon.jpg" }), file.bytes <= 4 << 20 {
            cover = try Data(contentsOf: directory.appendingPathComponent(file.path))
        }
        let preview = Preview(manifest: manifest, publisher: publisher, cover: cover,
                              manifestSHA256: SHA256.hash(data: rawManifest).map { String(format: "%02x", $0) }.joined())
        progressBytes?(copied, total)
        complete = true
        return (manifest, directory, publisher, preview)
    }

    /// Maps transport code to its preserved bytes, never the locally re-signed copy.
    static func transportFile(_ file: GamePackageManifest.File, in directory: URL) -> URL {
        let original = directory.appendingPathComponent("original.dylib")
        if file.executable, FileManager.default.fileExists(atPath: original.path) { return original }
        return directory.appendingPathComponent(file.path)
    }

    /// Verifies a received file set without first materializing a ZIP archive.
    /// The same path is used before forwarding installed game data to another device.
    static func inspectDirectory(_ directory: URL,
                                 progressBytes: ((UInt64, UInt64) -> Void)? = nil,
                                 onFile: (GamePackageManifest.File, UInt32) -> Void = { _, _ in }) throws -> Preview {
        func metadata(_ name: String, limit: Int) throws -> Data {
            let url = directory.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(limit) else {
                throw GamePackageError.invalid("invalid package metadata")
            }
            return try Data(contentsOf: url)
        }
        let raw = try metadata(GamePackageManifest.fileName, limit: NXBArchive.metadataLimit)
        let manifest = try JSONDecoder().decode(GamePackageManifest.self, from: raw)
        try manifest.validate()
        let allowed = Set(manifest.files.map(\.path) + [GamePackageManifest.fileName, "nxb.signature.json", "original.dylib"])
        guard let contents = FileManager.default.enumerator(atPath: directory.path) else {
            throw GamePackageError.invalid("unreadable package directory")
        }
        // Relative enumeration avoids /var versus /private/var URL aliases.
        for case let path as String in contents {
            let url = directory.appendingPathComponent(path)
            let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeDirectory { continue }
            guard type == .typeRegular, allowed.contains(path) else {
                throw GamePackageError.invalid("unlisted package file")
            }
        }
        var publisher: GamePackagePublisher?
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("nxb.signature.json").path) {
            publisher = try GamePackageSignature.verify(manifest: raw, proof: metadata("nxb.signature.json", limit: 64 << 10))
        }
        var cover: Data?
        let total = progressBytes == nil ? 0 : manifest.files.reduce(UInt64(0)) { $0 + $1.bytes }
        var checked: UInt64 = 0
        for file in manifest.files {
            let url = transportFile(file, in: directory)
            var parent = url.deletingLastPathComponent()
            while parent.path != directory.path {
                guard parent.path.hasPrefix(directory.path + "/"),
                      try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw GamePackageError.invalid("invalid package directory")
                }
                parent.deleteLastPathComponent()
            }
            let crc = try checksumFile(url, expected: file) { bytes in
                checked += bytes
                progressBytes?(checked, total)
            }
            onFile(file, crc)
            if file.path == "run/icon.jpg", file.bytes <= 4 << 20 { cover = try Data(contentsOf: url) }
        }
        let gameURL = directory.appendingPathComponent("run/game.json")
        try validateGameIdentity(Data(contentsOf: gameURL), manifest: manifest)
        return Preview(manifest: manifest, publisher: publisher, cover: cover,
                       manifestSHA256: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
    }

    private static func checksumFile(_ url: URL, expected file: GamePackageManifest.File,
                                     onBytes: (UInt64) -> Void) throws -> UInt32 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.uint64Value == file.bytes else {
            throw GamePackageError.invalid("file size or type mismatch")
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256(), crc: UInt32 = 0xffffffff
        var remaining = file.bytes
        while remaining > 0 {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: Int(min(remaining, UInt64(NXBArchive.chunk)))), !bytes.isEmpty else {
                throw GamePackageError.invalid("truncated file")
            }
            hash.update(data: bytes); crc = NXBArchive.updateCRC(crc, bytes)
            remaining -= UInt64(bytes.count)
            onBytes(UInt64(bytes.count))
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            throw GamePackageError.invalid("file checksum mismatch")
        }
        return crc ^ 0xffffffff
    }

    /// Streams a new NXB from installed immutable assets, with no temporary archive.
    /// An explicit file export can supply a FileHandle as the sink instead.
    static func streamDirectory(_ directory: URL, proof: Data? = nil,
                                progress: ((Int, Int) -> Void)? = nil, emit: (Data) throws -> Void) throws {
        var entries: [String: NXBArchive.Entry] = [:]
        let preview = try inspectDirectory(directory) { file, crc in
            entries[file.path] = NXBArchive.Entry(path: file.path, bytes: file.bytes, crc: crc, start: 0, end: file.bytes)
        }
        let raw = try Data(contentsOf: directory.appendingPathComponent(GamePackageManifest.fileName))
        let proofURL = directory.appendingPathComponent("nxb.signature.json")
        let signature = try proof ?? (FileManager.default.fileExists(atPath: proofURL.path) ? Data(contentsOf: proofURL) : nil)
        if let signature { _ = try GamePackageSignature.verify(manifest: raw, proof: signature) }
        let sources = Dictionary(uniqueKeysWithValues: preview.manifest.files.map { ($0.path, transportFile($0, in: directory)) })
        var input: FileHandle?, currentPath: String?
        defer { try? input?.close() }
        try NXBArchive.write(entries: entries, files: preview.manifest.files, manifest: raw, proof: signature, progress: progress,
            read: { path, offset, count in
                if currentPath != path {
                    try input?.close()
                    input = try FileHandle(forReadingFrom: sources[path]!)
                    currentPath = path
                }
                try input!.seek(toOffset: offset)
                return try input!.read(upToCount: count) ?? Data()
            }, emit: emit)
    }

    static func exportDirectory(_ directory: URL, to output: URL, progress: ((Int, Int) -> Void)? = nil,
                                signManifest: (Data) throws -> Data) throws {
        let raw = try Data(contentsOf: directory.appendingPathComponent(GamePackageManifest.fileName))
        let proof = try signManifest(raw)
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".nxb-export-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw GamePackageError.invalid("cannot create export")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try streamDirectory(directory, proof: proof, progress: progress) { try handle.write(contentsOf: $0) }
            try handle.synchronize(); try handle.close()
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch { try? handle.close(); throw error }
    }

}
