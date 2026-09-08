// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CineKit", targets: ["CineKit"])
    ],
    targets: [
        .target(
            name: "CineKit"
        ),
        .testTarget(name: "CineKitTests", dependencies: ["CineKit"]),
    ]
)
