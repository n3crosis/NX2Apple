import Foundation

/// A native build failure may carry paths and compiler source excerpts. Read
/// only a bounded, recognized diagnostic and never retain the original text.
public struct NativeGameBuildFailure: Error, Sendable {
    /// Recognized shader identifier, not original compiler text.
    public let shader: String?
    /// Allowlisted stable compiler diagnostic, when available.
    public let reason: String?

    public init(diagnostic: String) {
        let prefix = String(decoding: diagnostic.utf8.prefix(4096), as: UTF8.self)
        let header = #"^shader [0-9a-f]{16}(?:_[a-z]{1,4})? compilation: "#
        if let match = prefix.range(of: header, options: .regularExpression) {
            shader = prefix[match].split(separator: " ").dropFirst().first.map { String($0) }
            let explanation = prefix[match.upperBound...]
            // Match whole known reasons, rather than echoing arbitrary compiler text.
            reason = ["thread", "threadgroup", "device"].first {
                explanation == #""front end rejected: unsupported:rejected:addrspace-value:\#($0)""#
            }.map { "addrspace-value:\($0)" }
        } else {
            shader = nil
            reason = nil
        }
    }
}

/// Only structured stages, counts, version identifiers and recognized reasons
/// go into the copied report. Job logs and localized error strings stay out.
struct GameBuildReport {
    enum Failure: String {
        case signingIdentity = "signing_identity"
        case buildFailed = "build_failed"
        case installFailed = "install_failed"
    }

    private var recent: [String] = []

    mutating func record(_ progress: GameBuildProgress) {
        var entry = progress.stage
        if let detail = progress.detail { entry += "." + detail }
        if let done = progress.completedFiles, let total = progress.totalFiles {
            entry += " \(done)/\(total)"
        }
        guard entry != recent.last else { return }
        recent.append(entry)
        if recent.count > 24 { recent.removeFirst() }
    }

    func text(failure: Failure, native: NativeGameBuildFailure? = nil,
              info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String {
        var lines = ["NX2Apple build report"]
        for (key, label, pattern) in [
            ("CFBundleShortVersionString", "App version", #"^[0-9]+(?:\.[0-9]+){0,3}$"#),
            ("CFBundleVersion", "App build", #"^[0-9]+(?:\.[0-9]+){0,3}$"#),
            ("NXKitRuntimeRevision", "Runtime revision", #"^[0-9a-f]{40}$"#)
        ] {
            if let value = info[key] as? String, value.utf8.count <= 40,
               value.range(of: pattern, options: .regularExpression) == (value.startIndex..<value.endIndex) {
                lines.append("\(label): \(value)")
            }
        }
        if let abi = info["NXKitRuntimeABI"] as? Int, let number = UInt32(exactly: abi), number > 0 {
            lines.append("Runtime ABI: \(number)")
        }
        lines.append("Failure: \(failure.rawValue)")
        if let shader = native?.shader { lines.append("Shader: \(shader)") }
        if let reason = native?.reason { lines.append("Reason: \(reason)") }
        if !recent.isEmpty { lines.append("Progress (most recent last):"); lines += recent }
        return lines.joined(separator: "\n")
    }
}
