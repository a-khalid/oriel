// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nafitha",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nafitha", targets: ["Nafitha"]),
        .library(name: "NafithaCore", targets: ["NafithaCore"]),
    ],
    targets: [
        // Everything that talks to Virtualization.framework. No UI code here.
        .target(
            name: "NafithaCore",
            linkerSettings: [.linkedFramework("Virtualization")]
        ),
        // SwiftUI front end. Bundled into Nafitha.app by scripts/build-app.sh.
        .executableTarget(
            name: "Nafitha",
            dependencies: ["NafithaCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Headless boot check: scripts/smoke.sh <linux-arm64.iso>
        .executableTarget(
            name: "nafitha-smoke",
            dependencies: ["NafithaCore"],
            path: "Sources/NafithaSmoke"
        ),
        .testTarget(
            name: "NafithaCoreTests",
            dependencies: ["NafithaCore"]
        ),
    ]
)
