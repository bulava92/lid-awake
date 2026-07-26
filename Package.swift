// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LidAwake",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lid-awake", targets: ["LidAwakeCLI"]),
        .executable(name: "lid-awake-agent", targets: ["LidAwakeAgent"]),
        .executable(name: "LidAwakeApp", targets: ["LidAwakeApp"]),
        .executable(name: "lid-awake-self-test", targets: ["LidAwakeSelfTest"])
    ],
    targets: [
        .target(name: "LidAwakeCore"),
        .executableTarget(name: "LidAwakeCLI", dependencies: ["LidAwakeCore"]),
        .executableTarget(
            name: "LidAwakeAgent",
            dependencies: ["LidAwakeCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "LidAwakeApp",
            dependencies: ["LidAwakeCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "LidAwakeSelfTest", dependencies: ["LidAwakeCore"]),
        .testTarget(
            name: "LidAwakeCoreTests",
            dependencies: ["LidAwakeCore"]
        )
    ]
)
