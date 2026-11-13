// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ShellUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ShellUI", targets: ["ShellUI"]),
        // The controller adapter: GameController input turned into ShellInput, kept apart from the views.
        .library(name: "ShellControllers", targets: ["ShellControllers"]),
        // The host layer behind the views: catalogue, settings, game data, cloud saves, log and the launcher seam.
        .library(name: "ShellHost", targets: ["ShellHost"]),
        .executable(name: "ShellDemo", targets: ["ShellDemo"])
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git",
                 revision: "e61a288a9bc49a0358ab61614cac3d0553472254"),
        .package(url: "https://github.com/n3crosis/zsign.git",
                 revision: "ccfe8f7fe273d63568ffb9e7fd494d95e3ddd812")
    ],
    targets: [
        // The signing backend is included in every shell build, not an opt-in stub.
        .target(name: "NativeSigning", dependencies: [
            .product(name: "zsignc", package: "zsign"),
            .product(name: "OpenSSL", package: "OpenSSL-Package")
        ]),
        .target(name: "ShellUI", resources: [.process("Resources")]),
        .target(name: "ShellControllers", dependencies: ["ShellUI"]),
        .target(name: "ShellHost", dependencies: ["ShellUI", "ShellControllers", "NativeSigning"], resources: [.process("Resources")]),
        .executableTarget(name: "ShellDemo", dependencies: ["ShellUI", "ShellControllers", "ShellHost"], resources: [.process("Resources")]),
        .testTarget(name: "ShellUITests", dependencies: ["ShellUI"]),
        .testTarget(name: "ShellHostTests", dependencies: ["ShellHost", "ShellUI", "ShellControllers"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ShellControllersTests", dependencies: ["ShellControllers", "ShellUI"])
    ],
    cxxLanguageStandard: .cxx17
)
