// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Luma",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Luma", targets: ["Luma"])],
    targets: [
        .systemLibrary(
            name: "CMPV",
            path: "Sources/CMPV",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        .executableTarget(
            name: "Luma",
            dependencies: ["CMPV"],
            path: "Sources/Luma",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("OpenGL"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(name: "LumaTests", dependencies: ["Luma"], path: "Tests/LumaTests")
    ],
    swiftLanguageModes: [.v5]
)
