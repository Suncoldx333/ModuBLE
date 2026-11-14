// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModuBLE",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ModuBLE", targets: ["ModuBLE"])
    ],
    targets: [
        .target(name: "ModuBLE"),
        .testTarget(name: "ModuBLETests", dependencies: ["ModuBLE"])
    ]
)
