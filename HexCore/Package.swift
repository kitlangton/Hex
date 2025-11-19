// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HexCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HexCore", targets: ["HexCore"]),
    ],
	    dependencies: [
	        .package(url: "https://github.com/Clipy/Sauce", branch: "master"),
	        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
	        .package(url: "https://github.com/apple/swift-log", from: "1.6.4"),
	        .package(url: "https://github.com/Cocoanetics/SwiftMCP.git", branch: "main"),
	    ],
    targets: [
	    .target(
	        name: "HexCore",
	        dependencies: [
	            "Sauce",
	            .product(name: "Dependencies", package: "swift-dependencies"),
	            .product(name: "DependenciesMacros", package: "swift-dependencies"),
	            .product(name: "Logging", package: "swift-log"),
	            .product(name: "SwiftMCP", package: "SwiftMCP"),
	        ],
	        path: "Sources/HexCore",
	        resources: [
	            .copy("Resources")
	        ],
	        linkerSettings: [
	            .linkedFramework("IOKit")
	        ]
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
