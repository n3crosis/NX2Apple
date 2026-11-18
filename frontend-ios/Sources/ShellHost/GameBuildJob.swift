import Foundation

public struct GameBuildProgress: Sendable {
    public let stage: String
    public let message: String
    public init(stage: String, message: String) {
        self.stage = stage
        self.message = message
    }
}

/// One private build at a time. Credentials are deliberately not part of the job.
struct GameBuildJob: Codable, Sendable {
    @MainActor static var running = false

    struct Source: Codable, Sendable {
        let name: String
        let bookmark: Data

        // Match BookmarkStore: macOS needs a persistent sandbox scope; iOS
        // preserves the document picker's grant in a normal bookmark.
        #if os(macOS)
        private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        private static let createOptions: URL.BookmarkCreationOptions = []
        private static let resolveOptions: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif

        init(_ url: URL) throws {
            name = url.lastPathComponent
            bookmark = try url.bookmarkData(options: Self.createOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        }

        func resolve(in work: URL, slot: String) throws -> URL {
            let snapshot = work.appendingPathComponent("inputs/\(slot)/\(name)")
            if FileManager.default.fileExists(atPath: snapshot.path) { return snapshot }
            var stale = false
            return try URL(resolvingBookmarkData: bookmark, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    var id = UUID()
    let input: Source
    let updates: [Source]
    let dlc: [Source]
    var stage = "inputs"
    var logs: [String] = []

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameBuildJob", isDirectory: true)
    }

    static func exists(in directory: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    static func load(in directory: URL = directory) throws -> GameBuildJob {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("job.json")))
    }

    static func isCurrent(id: UUID?, exists expectedExistence: Bool, in directory: URL = directory) -> Bool {
        exists(in: directory) == expectedExistence && (try? load(in: directory))?.id == id
    }

    func save(in directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("job.json"), options: .atomic)
    }

    static func discard(in directory: URL = directory) throws {
        if exists(in: directory) { try FileManager.default.removeItem(at: directory) }
    }
}
