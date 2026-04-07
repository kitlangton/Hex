// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HexCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HexCore", targets: ["HexCore"]),
        .executable(name: "hex-cli", targets: ["HexCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Clipy/Sauce", branch: "master"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.9.1"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.15.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", branch: "main"),
    ],
    targets: [
	    .target(
	        name: "HexCore",
	        dependencies: [
	            "Sauce",
	            .product(name: "Dependencies", package: "swift-dependencies"),
	            .product(name: "DependenciesMacros", package: "swift-dependencies"),
	            .product(name: "Logging", package: "swift-log"),
	            .product(name: "WhisperKit", package: "WhisperKit"),
	            .product(name: "FluidAudio", package: "FluidAudio"),
	        ],
	        path: "Sources/HexCore",
	        linkerSettings: [
	            .linkedFramework("IOKit")
	        ]
	    ),
	    .executableTarget(
	        name: "HexCLI",
	        dependencies: [
	            "HexCore",
	        ],
	        path: "Sources/HexCLI"
	    ),
        .testTarget(
            name: "HexCoreTests",
            dependencies: ["HexCore"],
            path: "Tests/HexCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
