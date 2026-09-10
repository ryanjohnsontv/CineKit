// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CineKit", targets: ["CineKit"])
    ],
    targets: [
        .plugin(
            name: "MetalShaderPlugin",
            capability: .buildTool()
        ),
        .target(
            name: "CineKit",
            plugins: [
                "MetalShaderPlugin",
            ]
        ),
        .testTarget(name: "CineKitTests", dependencies: ["CineKit"]),
    ]
)
