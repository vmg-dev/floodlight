// swift-tools-version: 5.10

import Foundation
import PackageDescription

let localArtifactPath = "Artifacts/CFFF.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localArtifactURL = packageDirectory.appendingPathComponent(localArtifactPath)
let binaryVersion = "0.2.1"
let binaryChecksum = "900b222ced0ee8921cc35b037309d3957c32c4675ca0d12eef3a89370c418e23"
let cfffTarget: Target = FileManager.default.fileExists(atPath: localArtifactURL.path)
    ? .binaryTarget(name: "CFFF", path: localArtifactPath)
    : .binaryTarget(
        name: "CFFF",
        url: "https://github.com/vmg-dev/fff-swift/releases/download/\(binaryVersion)/CFFF.xcframework.zip",
        checksum: binaryChecksum
    )

let package = Package(
    name: "FFFKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FFFKit", targets: ["FFFKit"])
    ],
    targets: [
        cfffTarget,
        .target(
            name: "FFFKit",
            dependencies: ["CFFF"],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedLibrary("iconv"),
                .linkedLibrary("z")
            ]
        ),
        .testTarget(name: "FFFKitTests", dependencies: ["FFFKit"])
    ],
    swiftLanguageVersions: [.v5]
)
