// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Floodlight",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Floodlight", targets: ["Floodlight"])
    ],
    dependencies: [
        .package(path: "Vendor/fff-swift")
    ],
    targets: [
        .executableTarget(
            name: "Floodlight",
            dependencies: [
                .product(name: "FFFKit", package: "fff-swift")
            ],
            path: "Sources/Floodlight",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "FloodlightTests",
            dependencies: ["Floodlight"],
            path: "Tests/FloodlightTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
