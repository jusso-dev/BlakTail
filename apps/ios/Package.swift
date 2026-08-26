// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlakTailPhone",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BlakTailPhone", targets: ["BlakTailPhone"])
    ],
    dependencies: [
        .package(path: "../macos")
    ],
    targets: [
        .target(
            name: "BlakTailPhone",
            dependencies: [
                .product(name: "BlakTailCore", package: "macos")
            ],
            path: "Sources/BlakTailPhone"
        ),
        .testTarget(
            name: "BlakTailPhoneTests",
            dependencies: ["BlakTailPhone"],
            path: "Tests/BlakTailPhoneTests"
        )
    ]
)
