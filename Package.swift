// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxType",
    platforms: [.macOS("13.3")],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.32.0"),
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        .executableTarget(
            name: "VoxType",
            dependencies: ["whisper", .product(name: "Sentry", package: "sentry-cocoa")],
            path: "VoxType",
            exclude: ["Info.plist", "README.md", "Nodio.entitlements", "Fix Nodio.terminal"],
            resources: [.copy("Resources/mic.svg"), .copy("AppIcon.icns")],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)