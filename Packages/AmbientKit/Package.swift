// swift-tools-version: 6.0
import PackageDescription

// One target per subsystem. Every subsystem depends only on AmbientContracts, never on a sibling,
// so each can be built and tested alone: `swift build --target AmbientMemory`.
let package = Package(
    name: "AmbientKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "AmbientKit",
            targets: ["AmbientContracts", "AmbientAgent", "AmbientBackground", "AmbientConnectors", "AmbientMemory", "AmbientUI"]
        )
    ],
    targets: [
        .target(name: "AmbientContracts"),

        .target(name: "AmbientAgent", dependencies: ["AmbientContracts"]),
        .testTarget(name: "AmbientAgentTests", dependencies: ["AmbientAgent"]),

        .target(name: "AmbientBackground", dependencies: ["AmbientContracts"]),
        .testTarget(name: "AmbientBackgroundTests", dependencies: ["AmbientBackground"]),

        .target(name: "AmbientConnectors", dependencies: ["AmbientContracts"]),
        .testTarget(name: "AmbientConnectorsTests", dependencies: ["AmbientConnectors"]),

        // BuiltInSkills holds one folder per skill that ships with the app, each with a SKILL.md.
        .target(name: "AmbientMemory", dependencies: ["AmbientContracts"], resources: [.copy("BuiltInSkills")]),
        .testTarget(name: "AmbientMemoryTests", dependencies: ["AmbientMemory"]),

        .target(name: "AmbientUI", dependencies: ["AmbientContracts"], resources: [.copy("Sounds")]),
        .testTarget(name: "AmbientUITests", dependencies: ["AmbientUI"]),
        // Runs the interface alone with scripted states, to look at it without the rest of the app.
        .executableTarget(name: "AmbientUIDemo", dependencies: ["AmbientUI"]),
    ],
    swiftLanguageModes: [.v5]
)
