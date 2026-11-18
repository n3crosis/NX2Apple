import Foundation

/// Imported NXB games are independent of legacy framework bundles. The original
/// archive remains unchanged; only the private installed executable is re-signed.
public struct GamePackageLibrary: Sendable {
    private static let activationLock = NSRecursiveLock()
    public struct Prepared: Sendable, Identifiable {
        public let id: UUID
        public let archive: URL
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

    public func prepare(_ source: URL) throws -> Prepared {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let archive = root.appendingPathComponent(".import-\(id.uuidString).nxb")
        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do { try fm.copyItem(at: readable, to: archive) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            let preview = try GamePackage.inspect(archive, verifyPublisher: Self.verifyPublisher)
            return Prepared(id: id, archive: archive, preview: preview)
        } catch {
            try? fm.removeItem(at: archive)
            throw error
        }
    }

    public func discard(_ prepared: Prepared) {
        try? FileManager.default.removeItem(at: prepared.archive)
    }

    /// External packages require preview confirmation, including unsigned or unknown
    /// publishers. Local builds install directly. Both verify and sign before activation.
    public func install(_ prepared: Prepared,
                        checkCompatibility: (GamePackageManifest) throws -> Void,
                        sign: (URL) throws -> Void) throws -> Entry {
        let fm = FileManager.default
        let staged = try GamePackage.stage(prepared.archive, in: root, allowUnsigned: true,
            verifyPublisher: Self.verifyPublisher, allowUnknownPublisher: true) { manifest in
                guard manifest == prepared.preview.manifest else {
                    throw GamePackageError.invalid("package changed since preview")
                }
                try checkCompatibility(manifest)
            }
        defer { try? fm.removeItem(at: staged.directory) }
        guard staged.publisher?.keyID == prepared.preview.publisher?.keyID,
              staged.publisher?.certificateSHA256 == prepared.preview.publisher?.certificateSHA256 else {
            throw GamePackageError.invalid("publisher changed since preview")
        }
        try sign(staged.directory.appendingPathComponent("run/nxgame.dylib"))
        try fm.copyItem(at: prepared.archive, to: staged.directory.appendingPathComponent("original.nxb"))
        let titleRoot = root.appendingPathComponent(staged.manifest.titleID, isDirectory: true)
        try fm.createDirectory(at: titleRoot, withIntermediateDirectories: true)
        // A new local generation avoids mutating an installed or loaded image.
        let generation = UUID().uuidString.lowercased()
        let destination = titleRoot.appendingPathComponent(generation, isDirectory: true)
        Self.activationLock.lock()
        defer { Self.activationLock.unlock() }
        try fm.moveItem(at: staged.directory, to: destination)
        do {
            try Data(generation.utf8).write(to: titleRoot.appendingPathComponent("active"), options: .atomic)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        discard(prepared)
        return Entry(manifest: staged.manifest, directory: destination)
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
                if !loaded.contains(url) { try fm.removeItem(at: url) }
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
