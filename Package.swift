// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WAVCaptureKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "WAVCaptureKit", targets: ["WAVCaptureKit"]),
        .library(name: "WAVHTTPKit", targets: ["WAVHTTPKit"])
    ],
    targets: [
        .target(
            name: "WAVCaptureKit",
            path: "ios/Fitcore/Core/Audio"
        ),
        .target(
            name: "WAVHTTPKit",
            path: "ios/Fitcore/Core/WAVHTTP"
        ),
        .testTarget(
            name: "WAVCaptureKitTests",
            dependencies: ["WAVCaptureKit"],
            path: "tests/WAVCaptureKitTests"
        ),
        .testTarget(
            name: "WAVHTTPKitTests",
            dependencies: ["WAVHTTPKit"],
            path: "tests/WAVHTTPKitTests"
        )
    ]
)
