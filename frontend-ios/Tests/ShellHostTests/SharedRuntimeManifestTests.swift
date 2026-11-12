import Foundation
import Testing
@testable import ShellHost
import ShellUI

struct SharedRuntimeManifestTests {
    private let runtime = SharedRuntimeDescriptor(abi: 1, profileABI: 1, runtimeVersion: "test-build")

    private func manifest(loader: String = "FS", descriptor: SharedRuntimeDescriptor? = nil, profile: String = "profile.tsv") throws -> GameManifest {
        var value: [String: Any] = [
            "schema": 1, "title_id": "0100000000000001", "name": "Shared fixture",
            "display_version": "1", "package_version": "1", "modules": ["main"], "nro_count": 0,
            "chain": "b-abcd", "loader": loader, "framework": "Fixture.framework",
            "framework_executable": "Fixture", "image_marker": "fixture",
            "profile": profile, "shader_map": "shader_map.bin", "launcher": "launcher.json",
            "romfs_marker": "fixture", "romfs_identity": "", "min_os": "1.0"
        ]
        if let descriptor {
            value["shared_runtime"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor))
        }
        return try GameManifest.parse(JSONSerialization.data(withJSONObject: value))
    }

    private func state(_ manifest: GameManifest, chain: String? = "b-abcd", runtime: SharedRuntimeDescriptor?) -> GameState {
        let entry = CatalogueEntry(id: manifest.titleID, directory: URL(fileURLWithPath: "/fixture"), manifest: manifest)
        let data = DataResolution(url: URL(fileURLWithPath: "/data"), source: .app, pickedIsStale: false)
        return GameStateResolver.state(for: entry, data: data,
                                       environment: HostEnvironment(chain: chain, sharedRuntime: runtime))
    }

    @Test func sharedModeRequiresDescriptor() {
        #expect(throws: GameProblem.self) { try manifest() }
    }

    @Test func sharedModeRequiresExactHostCompatibility() throws {
        let game = try manifest(descriptor: runtime)
        #expect(state(game, runtime: runtime) == .playable)
        #expect(state(game, runtime: nil) == .needsAppUpdate)
        #expect(state(game, chain: nil, runtime: runtime) == .needsAppUpdate)
        #expect(state(game, chain: "b-ffff", runtime: runtime) == .needsAppUpdate)
        #expect(state(game, runtime: .init(abi: 2, profileABI: 1, runtimeVersion: "test-build")) == .needsAppUpdate)
        #expect(state(game, runtime: .init(abi: 1, profileABI: 2, runtimeVersion: "test-build")) == .needsAppUpdate)
        #expect(state(game, runtime: .init(abi: 1, profileABI: 1, runtimeVersion: "other-build")) == .needsAppUpdate)
    }

    @Test func legacyEmbeddedHostsRemainIndependent() throws {
        let game = try manifest(loader: "FH")
        #expect(game.sharedRuntime == nil)
        #expect(state(game, chain: "b-ffff", runtime: nil) == .playable)
        #expect(state(game, chain: nil, runtime: runtime) == .playable)
    }

    @Test func malformedDescriptorsAreRejected() {
        for bad in [SharedRuntimeDescriptor(abi: 0, profileABI: 1, runtimeVersion: "v1"),
                    .init(abi: 1, profileABI: -1, runtimeVersion: "v1"),
                    .init(abi: 1, profileABI: 1, runtimeVersion: ""),
                    .init(abi: 1, profileABI: 1, runtimeVersion: "a/b")] {
            #expect(throws: GameProblem.self) { try manifest(descriptor: bad) }
        }
    }

    @Test func sharedProfileCannotEscapeFramework() {
        for path in ["/profile.tsv", "../profile.tsv", "sub/../../profile.tsv", "sub//profile.tsv", ""] {
            #expect(throws: GameProblem.self) { try manifest(descriptor: runtime, profile: path) }
        }
    }

    @Test func descriptorCannotSelectLegacyRoute() {
        #expect(throws: GameProblem.self) { try manifest(loader: "FH", descriptor: runtime) }
    }
    @Test func routeCannotBeOverriddenByUserSettings() throws {
        for loader in ["FH", "FS"] {
            let descriptor: SharedRuntimeDescriptor? = loader == "FS" ? runtime : nil
            let parsed = try manifest(loader: loader, descriptor: descriptor)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let game = LaunchableGame(titleID: parsed.titleID, name: parsed.name, manifest: parsed,
                                      directory: root, frameworkURL: root, dataURL: root,
                                      appFolder: root, environment: ["DM_SHARED_RUNTIME": loader == "FS" ? "0" : "1", "DM_PROFILE": "/untrusted/profile"],
                                      cloudSavesURL: nil)
            let plan = EngineLaunchPlan.make(game: game, appResources: root, documents: root,
                                            envFileText: "DM_SHARED_RUNTIME=1", gameEnvFileText: "DM_SHARED_RUNTIME=0")
            #expect(plan.environment["DM_SHARED_RUNTIME"] == (loader == "FS" ? "1" : "0"))
            if loader == "FS" {
                #expect(plan.environment["DM_PROFILE"] == root.appendingPathComponent(parsed.profile).path)
            } else {
                #expect(plan.environment["DM_PROFILE"] == "/untrusted/profile")
            }
        }
    }

}
