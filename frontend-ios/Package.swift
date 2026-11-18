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
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.2"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.34.0"),
        .package(url: "https://github.com/n3crosis/zsign.git",
                 revision: "0a92e9a5be42758023b0bf7a885076f222a5015b")
    ],
    targets: [
        .target(name: "ShellUI", resources: [.process("Resources")]),
        .target(name: "ShellControllers", dependencies: ["ShellUI"]),
        .target(name: "ShellHost", dependencies: ["ShellUI", "ShellControllers",
            .product(name: "zsignc", package: "zsign"),
            .product(name: "Vapor", package: "vapor"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")], resources: [.process("Resources")]),
        .executableTarget(name: "ShellDemo", dependencies: ["ShellUI", "ShellControllers", "ShellHost"], resources: [.process("Resources")]),
        .testTarget(name: "ShellUITests", dependencies: ["ShellUI"]),
        .testTarget(name: "ShellHostTests", dependencies: ["ShellHost", "ShellUI", "ShellControllers"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ShellControllersTests", dependencies: ["ShellControllers", "ShellUI"])
    ]
)
