// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pegel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pegel", targets: ["Pegel"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Pegel",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Pegel",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
