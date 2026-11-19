import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Imported NXB games are independent of legacy framework bundles. Game assets
/// are stored once; only the executable keeps a transport and a locally signed copy.
public struct GamePackageLibrary: Sendable {
    public enum InstallationError: Error { case alreadyInstalled }
    private static let activationLock = NSRecursiveLock()
    // Protected by activationLock, including prune/remove in other windows.
    nonisolated(unsafe) private static var sharingDirectories: [URL: Int] = [:]

    static func retainSharing(_ directory: URL) {
        activationLock.lock()
        defer { activationLock.unlock() }
        sharingDirectories[directory.standardizedFileURL, default: 0] += 1
    }

    static func releaseSharing(_ directory: URL) {
        activationLock.lock()
        defer { activationLock.unlock() }
        let key = directory.standardizedFileURL
        let count = sharingDirectories[key, default: 0]
        if count <= 1 { sharingDirectories.removeValue(forKey: key) }
        else { sharingDirectories[key] = count - 1 }
    }
    public struct Prepared: Sendable, Identifiable {
        public let id: UUID
        public let directory: URL
        public let preview: GamePackage.Preview
    }

    public struct Entry: Sendable, Identifiable {
        public var id: String { manifest.titleID }
        public let manifest: GamePackageManifest
        public let directory: URL
        public var runRoot: URL { directory.appendingPathComponent("run", isDirectory: true) }
        public var archive: URL { directory.appendingPathComponent("original.nxb") }
    }

    public let root: URL
    public init(root: URL) { self.root = root }

    public func prepare(_ source: URL, allowUntrusted: Bool = true, progressBytes: ((UInt64, UInt64) -> Void)? = nil) throws -> Prepared {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Prepared, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            result = Result {
                let staged = try GamePackage.stage(readable, in: root, allowUnsigned: allowUntrusted,
                    verifyPublisher: Self.verifyPublisher, allowUnknownPublisher: allowUntrusted, progressBytes: progressBytes) { _ in }
                return Prepared(id: UUID(), directory: staged.directory, preview: staged.preview)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw GamePackageError.invalid("source file unavailable") }
        return try result.get()
    }

    /// A network receiver writes directly into a private staging directory under
    /// this library. Verification precedes preview and activation; no ZIP is retained.
    public func prepareDirectory(_ directory: URL) throws -> Prepared {
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              directory.lastPathComponent.hasPrefix(".nxb-"),
              try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw GamePackageError.invalid("invalid staging directory")
        }
        return Prepared(id: UUID(), directory: directory, preview: try GamePackage.inspectDirectory(directory))
    }

    /// Old installations still have original.nxb. New ones retain just the
    /// transport executable and share the installed data with future exports.
    public func prepare(_ entry: Entry) throws -> Prepared {
        let fm = FileManager.default
        if fm.fileExists(atPath: entry.archive.path) { return try prepare(entry.archive) }
        let directory = root.appendingPathComponent(".nxb-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            for name in [GamePackageManifest.fileName, "nxb.signature.json"] {
                let source = entry.directory.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: directory.appendingPathComponent(name)) }
            }
            for file in entry.manifest.files {
                let destination = directory.appendingPathComponent(file.path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.cloneOrCopy(GamePackage.transportFile(file, in: entry.directory), to: destination)
            }
            return try prepareDirectory(directory)
        } catch { try? fm.removeItem(at: directory); throw error }
    }

    public func discard(_ prepared: Prepared) {
        try? FileManager.default.removeItem(at: prepared.directory)
    }

    /// The staged files become the installed generation by rename, not copying.
    /// A failed replacement leaves the active generation and saves untouched.
    public func install(_ prepared: Prepared,
                        replaceExisting: Bool = true,
                        progress: (PackageImportStage) -> Void = { _ in },
                        checkCompatibility: (GamePackageManifest) throws -> Void,
                        sign: (URL) throws -> Void) throws -> Entry {
        let fm = FileManager.default
        let verified = try GamePackage.inspectDirectory(prepared.directory)
        guard verified.manifestSHA256 == prepared.preview.manifestSHA256,
              verified.publisher?.keyID == prepared.preview.publisher?.keyID,
              verified.publisher?.certificateSHA256 == prepared.preview.publisher?.certificateSHA256 else {
            throw GamePackageError.invalid("package changed since preview")
        }
        try checkCompatibility(verified.manifest)
        let titleRoot = root.appendingPathComponent(verified.manifest.titleID, isDirectory: true)
        if !replaceExisting && fm.fileExists(atPath: titleRoot.appendingPathComponent("active").path) {
            throw InstallationError.alreadyInstalled
        }
        let executable = prepared.directory.appendingPathComponent("run/nxgame.dylib")
        let original = prepared.directory.appendingPathComponent("original.dylib")
        if fm.fileExists(atPath: original.path) {
            if fm.fileExists(atPath: executable.path) { try fm.removeItem(at: executable) }
            try Self.cloneOrCopy(original, to: executable)
        } else { try Self.cloneOrCopy(executable, to: original) }
        try Task.checkCancellation()
        progress(.signing)
        try sign(executable)
        try Task.checkCancellation()
        let generation = UUID().uuidString.lowercased()
        let destination = titleRoot.appendingPathComponent(generation, isDirectory: true)
        Self.activationLock.lock()
        defer { Self.activationLock.unlock() }
        try fm.createDirectory(at: titleRoot, withIntermediateDirectories: true)
        let active = titleRoot.appendingPathComponent("active")
        if !replaceExisting && fm.fileExists(atPath: active.path) {
            throw InstallationError.alreadyInstalled
        }
        try Task.checkCancellation()
        progress(.installing)
        try fm.moveItem(at: prepared.directory, to: destination)
        do {
            try Task.checkCancellation()
            if replaceExisting {
                try Data(generation.utf8).write(to: active, options: .atomic)
            } else {
                // Publish a complete pointer without replacing an existing name,
                // even if another process installed the title after our check.
                let pointer = titleRoot.appendingPathComponent(".active-" + UUID().uuidString)
                defer { try? fm.removeItem(at: pointer) }
                try Data(generation.utf8).write(to: pointer, options: .withoutOverwriting)
                do { try fm.linkItem(at: pointer, to: active) }
                catch {
                    let failure = error as NSError
                    if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteFileExistsError) ||
                        (failure.domain == NSPOSIXErrorDomain && failure.code == Int(EEXIST)) {
                        throw InstallationError.alreadyInstalled
                    }
                    throw error
                }
            }
        }
        catch {
            try? fm.moveItem(at: destination, to: prepared.directory)
            throw error
        }
        return Entry(manifest: verified.manifest, directory: destination)
    }

    public func entries() -> [Entry] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).compactMap { title in
            guard title.count == 16, title.allSatisfy({ $0.isHexDigit }), title == title.uppercased() else { return nil }
            let titleRoot = root.appendingPathComponent(title, isDirectory: true)
            guard let generation = try? String(contentsOf: titleRoot.appendingPathComponent("active"), encoding: .utf8),
                  UUID(uuidString: generation) != nil else { return nil }
            let directory = titleRoot.appendingPathComponent(generation, isDirectory: true)
            guard let bytes = try? Data(contentsOf: directory.appendingPathComponent(GamePackageManifest.fileName)),
                  let manifest = try? JSONDecoder().decode(GamePackageManifest.self, from: bytes),
                  (try? manifest.validate()) != nil, manifest.titleID == title,
                  fm.fileExists(atPath: directory.appendingPathComponent("run/nxgame.dylib").path) else { return nil }
            return Entry(manifest: manifest, directory: directory)
        }.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    /// Uses the installed transport bytes rather than the locally signed copy.
    public func exportForSharing(_ entry: Entry, to output: URL, progress: ((Int, Int) -> Void)? = nil) throws {
        Self.retainSharing(entry.directory)
        defer { Self.releaseSharing(entry.directory) }
        func sign(_ manifest: Data) throws -> Data {
            try ShellSigningIdentityStore().signPackageManifest(manifest)
        }
        if FileManager.default.fileExists(atPath: entry.archive.path) {
            try GamePackage.exportSigned(entry.archive, to: output, progress: progress, signManifest: sign)
        } else {
            try GamePackage.exportDirectory(entry.directory, to: output, progress: progress, signManifest: sign)
        }
    }

    /// Keep only active or still-loaded generations. A removed loaded package
    /// disappears immediately, but its files survive until the next process.
    public func prune(preserving loaded: Set<URL>) throws {
        Self.activationLock.lock()
        defer { Self.activationLock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        for title in try fm.contentsOfDirectory(atPath: root.path) where title.count == 16 && title.allSatisfy({ $0.isHexDigit }) {
            let directory = root.appendingPathComponent(title, isDirectory: true)
            let active = try? String(contentsOf: directory.appendingPathComponent("active"), encoding: .utf8)
            for generation in try fm.contentsOfDirectory(atPath: directory.path) where UUID(uuidString: generation) != nil && generation != active {
                let url = directory.appendingPathComponent(generation, isDirectory: true)
                if !loaded.contains(url), Self.sharingDirectories[url.standardizedFileURL] == nil {
                    try fm.removeItem(at: url)
                }
            }
            if try fm.contentsOfDirectory(atPath: directory.path).isEmpty { try fm.removeItem(at: directory) }
        }
    }

    public func remove(_ entry: Entry, preserving loaded: Set<URL>) throws {
        Self.activationLock.lock()
        defer { Self.activationLock.unlock() }
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.id).appendingPathComponent("active"))
        try prune(preserving: loaded)
    }

    /// APFS clones share storage, not writable inodes. Re-signing a staged copy
    /// cannot mutate the active generation. Other volumes use an independent copy.
    private static func cloneOrCopy(_ source: URL, to destination: URL) throws {
        #if canImport(Darwin)
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { clonefile(sourcePath, $0, UInt32(CLONE_NOFOLLOW)) }
        }
        if result == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EXDEV else {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        #endif
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func verifyPublisher(_ manifest: Data, _ proof: Data) throws -> GamePackagePublisher {
        try GamePackageSignature.verify(manifest: manifest, proof: proof)
    }
}

/// Implemented by the app's unified runtime adapter, never by the legacy
/// framework loader. An absent adapter leaves imported packages unplayable.
@MainActor public protocol GamePackageLauncher: Sendable {
    var isGameRunning: Bool { get }
    func checkCompatibility(_ manifest: GamePackageManifest) throws
    func launch(_ game: GamePackageLibrary.Entry, dataRoot: URL) async throws
}


/// All shell windows share one process and can retain the same native images.
@MainActor enum GamePackageSession {
    static var loadedDirectories: Set<URL> = []
}
