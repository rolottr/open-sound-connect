// swift-tools-version:6.0
// Sound Connect for Mac.
// scripts/build.sh wraps the SwiftPM executable into a signed macOS app bundle.
import PackageDescription

let package = Package(
    name: "SoundConnect",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SoundConnect", targets: ["SoundConnect"]),
        .executable(name: "SoundConnectArtwork", targets: ["SoundConnectArtwork"]),
    ],
    targets: [
        .testTarget(name: "SoundConnectTests", dependencies: ["SoundConnect"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "SoundConnect",
            path: "Sources/SoundConnect",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("SceneKit"),
            ]
        ),
        // Build-time tool: renders the app icon (and nothing else) with CoreGraphics into an .iconset.
        .executableTarget(
            name: "SoundConnectArtwork",
            path: "Sources/SoundConnectArtwork",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
