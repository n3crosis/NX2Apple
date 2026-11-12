import Foundation

/// Exact installed dependency, negotiated through the existing payload protocol.
/// FS uses schema 2 so older receivers cannot ignore this requirement.
public struct PayloadSharedRuntime: Codable, Sendable, Equatable {
    public var abi: Int
    public var profileABI: Int
    public var runtimeVersion: String
    public var chain: String

    public init(abi: Int, profileABI: Int, runtimeVersion: String, chain: String) {
        self.abi = abi; self.profileABI = profileABI
        self.runtimeVersion = runtimeVersion; self.chain = chain
    }

    public var isWellFormed: Bool {
        abi == 1 && profileABI == 1 && !runtimeVersion.isEmpty && runtimeVersion.utf8.count <= 128
            && runtimeVersion.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
            && chain.hasPrefix("b-") && chain.count > 2 && chain.count <= 130
            && chain.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    /// Reads the dependency from the game, never from a local runtime selected for export.
    public static func requirement(at framework: URL) throws -> Self? {
        let data = try Data(contentsOf: framework.appendingPathComponent("game.manifest.json"))
        guard let game = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PayloadError.invalid("game manifest")
        }
        return try requirement(game)
    }

    static func requirement(_ game: [String: Any]) throws -> Self? {
        guard let loader = game["loader"] as? String, ["FH", "FS"].contains(loader) else {
            throw PayloadError.incompatible("payload requires an FH or FS framework")
        }
        if loader == "FH" {
            guard game["shared_runtime"] == nil else { throw PayloadError.invalid("FH runtime dependency") }
            return nil
        }
        struct Descriptor: Decodable {
            let abi: Int
            let profile_abi: Int
            let runtime_version: String
        }
        guard let raw = game["shared_runtime"] as? [String: Any], let chain = game["chain"] as? String else {
            throw PayloadError.invalid("FS runtime dependency")
        }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: JSONSerialization.data(withJSONObject: raw))
        let result = Self(abi: descriptor.abi, profileABI: descriptor.profile_abi,
                          runtimeVersion: descriptor.runtime_version, chain: chain)
        guard result.isWellFormed else { throw PayloadError.incompatible("unsupported shared runtime dependency") }
        return result
    }
}

extension PayloadManifest {
    /// Bind the transport dependency to the hashed game metadata, on intake and before launch.
    /// Legacy FH keeps its existing metadata-validator behavior.
    public func validateGameMetadata(at frameworkURL: URL) throws {
        let data = try Data(contentsOf: frameworkURL.appendingPathComponent("game.manifest.json"))
        guard let game = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if sharedRuntime != nil { throw PayloadError.invalid("game manifest") }
            return
        }
        guard sharedRuntime != nil || game["loader"] as? String == "FS" else { return }
        guard try PayloadSharedRuntime.requirement(game) == sharedRuntime,
              game["loader"] as? String == "FS",
              game["title_id"] as? String == titleID,
              game["framework"] as? String == framework,
              game["framework_executable"] as? String == executable,
              game["min_os"] as? String == minOS else {
            throw PayloadError.invalid("FS payload and game metadata disagree")
        }
    }
}
