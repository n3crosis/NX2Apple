import Foundation

/// Kept outside build jobs so discarding or sharing a game never includes its keys.
struct GameBuildKeys: Sendable {
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GameBuildKeys", isDirectory: true)) {
        self.directory = directory
    }

    var url: URL { directory.appendingPathComponent("prod.keys") }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func save(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            result = Result {
                guard readable.pathExtension.lowercased() == "keys" else { throw CocoaError(.fileReadCorruptFile) }
                let file = try FileHandle(forReadingFrom: readable)
                defer { try? file.close() }
                // Keys are small text files. Do not load an accidentally selected game into memory.
                let data = try file.read(upToCount: 1_048_577) ?? Data()
                guard !data.isEmpty, data.count <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
                let fm = FileManager.default
                var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
                #if os(iOS)
                attributes[.protectionKey] = FileProtectionType.complete
                #endif
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
                var root = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                var options: Data.WritingOptions = [.atomic]
                #if os(iOS)
                options.insert(.completeFileProtection)
                #endif
                try data.write(to: url, options: options)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        try result.get()
    }

    func remove() throws {
        if exists { try FileManager.default.removeItem(at: url) }
    }
}
