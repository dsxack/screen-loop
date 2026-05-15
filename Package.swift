// swift-tools-version: 6.0

import PackageDescription

let developerFrameworksPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let developerLibraryPath = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "ScreenRecorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ScreenRecorderCore", targets: ["ScreenRecorderCore"]),
        .executable(name: "ScreenRecorderApp", targets: ["ScreenRecorderApp"])
    ],
    targets: [
        .target(
            name: "ScreenRecorderCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .executableTarget(
            name: "ScreenRecorderApp",
            dependencies: ["ScreenRecorderCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "ScreenRecorderCoreTests",
            dependencies: ["ScreenRecorderCore"],
            swiftSettings: [
                .unsafeFlags(["-I\(developerFrameworksPath)", "-F\(developerFrameworksPath)"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F\(developerFrameworksPath)",
                    "-L\(developerLibraryPath)",
                    "-Xlinker", "-rpath", "-Xlinker", developerFrameworksPath,
                    "-Xlinker", "-rpath", "-Xlinker", developerLibraryPath
                ]),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Testing")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
