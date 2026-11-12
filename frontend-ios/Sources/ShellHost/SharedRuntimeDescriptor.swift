import Foundation

/// Exact compatibility identity of the shared host and generated game profile.
/// A semantic version alone cannot establish compatibility with generated native code.
public struct SharedRuntimeDescriptor: Codable, Equatable, Sendable {
    public var abi: Int
    public var profileABI: Int
    public var runtimeVersion: String

    public init(abi: Int, profileABI: Int, runtimeVersion: String) {
        self.abi = abi
        self.profileABI = profileABI
        self.runtimeVersion = runtimeVersion
    }

    enum CodingKeys: String, CodingKey {
        case abi
        case profileABI = "profile_abi"
        case runtimeVersion = "runtime_version"
    }

    public var isWellFormed: Bool {
        abi > 0 && profileABI > 0 && !runtimeVersion.isEmpty && runtimeVersion.utf8.count <= 128
            && runtimeVersion.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || byte == 45 || byte == 46 || byte == 95
            }
    }
}
