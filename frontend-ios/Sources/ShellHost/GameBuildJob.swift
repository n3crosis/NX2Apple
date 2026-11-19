import Foundation

public struct GameBuildProgress: Sendable {
    public let stage: String
    public let message: String
    public let detail: String?
    /// Measured work units within this detail, not overall build percentage.
    /// Legacy field names remain stable for callers and saved jobs.
    public let completedFiles: Int?
    public let totalFiles: Int?
    private static let stages: Set<String> = ["inputs", "extract", "shaders", "analyze", "link", "resources", "archive", "prepared", "install", "signing"]
    private static let details: [String: String] = [
        "shaders.compile": "Compiling shader jobs", "shaders.deferred": "Preparing deferred shader jobs",
        "shaders.jobs": "Collecting shader jobs", "analyze.manifest": "Preparing analysis manifest",
        "extract.romfs": "Extracting game resources", "extract.dlc": "Extracting add-on content",
        "archive.hash": "Hashing payload files", "shaders.index": "Indexing shader resource candidates", "shaders.modules": "Scanning modules for shaders",
        "shaders.dictionaries": "Building shader dictionaries", "shaders.resources": "Preparing shader resources",
        "shaders.assemble": "Assembling shader metadata and jobs", "extract.read": "Reading game container",
        "extract.payload": "Extracting payload", "analyze.modules": "Analyzing modules",
        "link.image": "Linking image", "link.modules": "Linking modules",
        "resources.copy": "Copying resources", "resources.shaders": "Copying shader libraries",
        "archive.write": "Writing package", "signing.archive": "Writing signed package"
    ]
    public static func detailLabel(stage: String, detail: String?) -> String? {
        guard let detail else { return nil }
        return details[stage + "." + detail]
    }
    public var detailLabel: String? { Self.detailLabel(stage: stage, detail: detail) }
    public init(stage: String, message: String, completedFiles: Int? = nil, totalFiles: Int? = nil, detail: String? = nil) {
        self.stage = Self.stages.contains(stage) ? stage : "building"
        self.message = message
        self.detail = Self.detailLabel(stage: stage, detail: detail) != nil ? detail : nil
        if (stage == "inputs" || self.detail != nil), let completedFiles, let totalFiles,
           totalFiles > 0, (0...totalFiles).contains(completedFiles) {
            self.completedFiles = completedFiles
            self.totalFiles = totalFiles
        } else {
            self.completedFiles = nil
            self.totalFiles = nil
        }
    }

    /// Accept only the native bridge's bounded label grammar. No arbitrary text
    /// or paths from a native status string reach logs, UI or JSON output.
    public init(nativeStage: String) {
        guard !nativeStage.isEmpty, nativeStage.utf8.count <= 128 else { self.init(stage: "building", message: ""); return }
        let parts = nativeStage.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first else { self.init(stage: "building", message: ""); return }
        let label = first.split(separator: ".", omittingEmptySubsequences: false)
        guard let name = label.first else { self.init(stage: "building", message: ""); return }
        let stage = String(name)
        let detail = label.count == 2 ? String(label[1]) : nil
        guard label.count <= 2, parts.count == 1 || parts.count == 3 else {
            self.init(stage: "building", message: ""); return
        }
        func number(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(text)
        }
        self.init(stage: stage, message: "", completedFiles: parts.count == 3 ? number(parts[1]) : nil,
                  totalFiles: parts.count == 3 ? number(parts[2]) : nil, detail: detail)
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
    var detail: String?
    var logs: [String] = []
    var completedFiles: Int?
    var totalFiles: Int?

    /// Record only trusted stage labels and numeric counts, never the native
    /// message (which may contain source paths or credentials).
    mutating func record(_ event: GameBuildProgress, label: String, at date: Date = Date()) {
        let changed = stage != event.stage || detail != event.detail || completedFiles != event.completedFiles || totalFiles != event.totalFiles
        stage = event.stage
        detail = event.detail
        completedFiles = event.completedFiles
        totalFiles = event.totalFiles
        guard changed || logs.isEmpty else { return }
        let timestamp = date.formatted(date: .omitted, time: .standard)
        let count = completedFiles.flatMap { done in totalFiles.map { " (\(done)/\($0))" } } ?? ""
        let breakdown = event.detailLabel.map { " · " + $0 } ?? ""
        logs.append("[\(timestamp)] \(label)\(breakdown)\(count)")
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }

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
