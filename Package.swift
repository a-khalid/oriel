// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Oriel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Oriel", targets: ["Oriel"]),
        .library(name: "OrielCore", targets: ["OrielCore"]),
    ],
    targets: [
        // Everything that talks to Virtualization.framework. No UI code here.
        .target(
            name: "OrielCore",
            linkerSettings: [.linkedFramework("Virtualization")]
        ),
        // SwiftUI front end. Bundled into Oriel.app by scripts/build-app.sh.
        .executableTarget(
            name: "Oriel",
            dependencies: ["OrielCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Headless boot check: scripts/smoke.sh <linux-arm64.iso>
        .executableTarget(
            name: "oriel-smoke",
            dependencies: ["OrielCore"],
            path: "Sources/OrielSmoke"
        ),
        .testTarget(
            name: "OrielCoreTests",
            dependencies: ["OrielCore"]
        ),
    ]
)
