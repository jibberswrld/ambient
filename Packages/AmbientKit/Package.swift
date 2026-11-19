// swift-tools-version: 6.0
import PackageDescription

// One target per subsystem. Every subsystem depends only on AmbientContracts, never on a sibling,
// so each can be built and tested alone: `swift build --target AmbientMemory`.
let subsystemNames = ["AmbientAgent", "AmbientBackground", "AmbientConnectors", "AmbientMemory", "AmbientUI"]

let package = Package(
    name: "AmbientKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AmbientKit", targets: ["AmbientContracts"] + subsystemNames)
    ],
    targets: [.target(name: "AmbientContracts")]
        + subsystemNames.map { .target(name: $0, dependencies: ["AmbientContracts"]) }
        + subsystemNames.map { .testTarget(name: "\($0)Tests", dependencies: [.target(name: $0)]) },
    swiftLanguageModes: [.v5]
)
