// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pegel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pegel", targets: ["Pegel"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "Pegel",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Pegel",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
