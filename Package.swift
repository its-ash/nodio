// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxType",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VoxType",
            path: "VoxType",
            exclude: ["Info.plist", "README.md"],
            resources: [.copy("Resources/AppIcon.svg")],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Accelerate"),
            ]
        )
    ]
)