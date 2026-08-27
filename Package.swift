// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GoogleChatNotifier",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "GoogleChatNotifier",
            path: "Sources/GoogleChatNotifier"
        )
    ]
)
