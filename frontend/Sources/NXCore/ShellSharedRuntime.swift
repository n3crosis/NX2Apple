import Foundation

/// The runtime is replaced atomically, just like game frameworks. Keep the old
/// copy until project validation and shell.json both accept the new selection.
struct ShellRuntimeMirror {
    var path: String
    var previous: String?

    func rollback() {
        guard ShellInstall.discard(path) else { return }
        if let previous { try? FileManager.default.moveItem(atPath: previous, toPath: path) }
    }

    func commit() {
        if let previous { ShellInstall.discard(previous) }
    }
}

extension ShellInstall {
    package static func requiresSharedRuntime(_ framework: String, fm: FileManager = .default) -> Bool {
        guard let data = fm.contents(atPath: framework + "/game.manifest.json"),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return manifest["loader"] as? String == "FS"
    }

    package static func siblingSharedRuntime(_ framework: String) -> String {
        (framework as NSString).deletingLastPathComponent + "/DmSharedRuntime.framework"
    }

    package static func mirroredSharedRuntime(root: String) -> String {
        frameworksMirror(root: root) + "/DmSharedRuntime.framework"
    }

    /// Prefer the just-built game's runtime, then the saved selection, then a
    /// surviving build-folder sibling. build_shell.sh validates the selected
    /// runtime against every FS game before accepting the project.
    static func prepareSharedRuntime(root: String, library: inout ShellLibrary,
                                     preferredFramework: String, fm: FileManager = .default) throws -> ShellRuntimeMirror? {
        let sharedGames = library.games.filter { requiresSharedRuntime($0.framework, fm: fm) }
        guard !sharedGames.isEmpty else { return nil }
        var candidates: [String] = []
        if requiresSharedRuntime(preferredFramework, fm: fm) { candidates.append(siblingSharedRuntime(preferredFramework)) }
        if let saved = library.sharedRuntime { candidates.append(saved) }
        candidates += sharedGames.map { siblingSharedRuntime($0.framework) }
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            throw NSError(domain: "ShellSharedRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Missing DmSharedRuntime.framework beside the FS game. Build the shared runtime and game again."])
        }
        let mirror = mirroredSharedRuntime(root: root)
        if URL(fileURLWithPath: source).standardizedFileURL == URL(fileURLWithPath: mirror).standardizedFileURL {
            library.sharedRuntime = mirror
            return nil
        }
        let folder = frameworksMirror(root: root)
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let staged = folder + "/.runtime-staging-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: staged) }
        try fm.copyItem(atPath: source, toPath: staged)
        var previous: String?
        if fm.fileExists(atPath: mirror) {
            let backup = folder + "/.runtime-backup-" + UUID().uuidString
            try fm.moveItem(atPath: mirror, toPath: backup)
            previous = backup
        }
        do { try fm.moveItem(atPath: staged, toPath: mirror) }
        catch {
            if let previous { try? fm.moveItem(atPath: previous, toPath: mirror) }
            throw error
        }
        library.sharedRuntime = mirror
        return ShellRuntimeMirror(path: mirror, previous: previous)
    }
}
