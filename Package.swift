// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EventClock",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EventClockCore", targets: ["EventClockCore"]),
        .library(name: "EventClockPlatform", targets: ["EventClockPlatform"]),
    ],
    targets: [
        .target(name: "EventClockCore"),
        .target(
            name: "EventClockPlatform",
            dependencies: ["EventClockCore"]
        ),
        .testTarget(
            name: "EventClockCoreTests",
            dependencies: ["EventClockCore"]
        ),
        .testTarget(
            name: "EventClockPlatformTests",
            dependencies: ["EventClockPlatform"]
        ),
    ]
)
