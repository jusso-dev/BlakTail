// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlakTail",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BlakTailCore", targets: ["BlakTailCore"]),
        .executable(name: "BlakTail", targets: ["BlakTail"])
    ],
    targets: [
        .target(
            name: "BlakTailCore",
            path: "Sources/BlakTailCore"
        ),
        .executableTarget(
            name: "BlakTail",
            dependencies: ["BlakTailCore"],
            path: "Sources/BlakTail"
        ),
        .testTarget(
            name: "BlakTailTests",
            dependencies: ["BlakTailCore"],
            path: "Tests/BlakTailTests"
        )
    ]
)
