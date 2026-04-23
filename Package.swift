// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudioFollower",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AudioFollower",
            path: "Sources/AudioFollower",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
