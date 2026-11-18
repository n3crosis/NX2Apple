// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GameRuntime",
    platforms: [.iOS("26.0")],
    products: [.library(name: "GameRuntime", targets: ["GameRuntime"])],
    targets: [
        .systemLibrary(name: "CGameRuntime"),
        .target(name: "GameRuntime", dependencies: ["CGameRuntime"])
    ]
)
