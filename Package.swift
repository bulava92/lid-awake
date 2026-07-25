// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LidAwake",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lid-awake", targets: ["LidAwakeCLI"]),
        .executable(name: "lid-awake-agent", targets: ["LidAwakeAgent"]),
        .executable(name: "LidAwakeApp", targets: ["LidAwakeApp"])
    ],
    targets: [
        .target(name: "LidAwakeCore"),
        .executableTarget(name: "LidAwakeCLI", dependencies: ["LidAwakeCore"]),
        .executableTarget(
            name: "LidAwakeAgent",
            dependencies: ["LidAwakeCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("UserNotifications")]
        ),
        .executableTarget(
            name: "LidAwakeApp",
            dependencies: ["LidAwakeCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "LidAwakeCoreTests", dependencies: ["LidAwakeCore"])
    ]
)
