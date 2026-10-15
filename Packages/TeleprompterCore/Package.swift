// swift-tools-version:5.9
import PackageDescription

// Pure Swift engine for the teleprompter: script tokenizing, speech-to-script
// matching, reading pace estimation and scroll physics. No UIKit, no audio,
// so every piece can be unit tested on any platform.
let package = Package(
    name: "TeleprompterCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TeleprompterCore", targets: ["TeleprompterCore"])
    ],
    targets: [
        .target(name: "TeleprompterCore"),
        .testTarget(
            name: "TeleprompterCoreTests",
            dependencies: ["TeleprompterCore"]
        )
    ]
)
