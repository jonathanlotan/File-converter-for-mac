// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConverterCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ConverterCore", targets: ["ConverterCore"]),
        .executable(name: "converter-cli", targets: ["converter-cli"]),
    ],
    targets: [
        .target(name: "ConverterCore"),
        .executableTarget(name: "converter-cli", dependencies: ["ConverterCore"]),
        .testTarget(name: "ConverterCoreTests", dependencies: ["ConverterCore"]),
    ]
)
