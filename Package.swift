// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LidAwake",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lid-awake", targets: ["LidAwakeCLI"]),
        .executable(name: "lid-awake-agent", targets: ["LidAwakeAgent"]),
        .executable(name: "lid-awake-scheduler", targets: ["LidAwakeScheduler"]),
        .executable(name: "lid-awake-schedule-editor", targets: ["LidAwakeScheduleEditor"]),
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
            name: "LidAwakeScheduler",
            dependencies: ["LidAwakeCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "LidAwakeScheduleEditor",
            dependencies: ["LidAwakeCore"],
            linkerSettings: [.linkedFramework("AppKit")]
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
