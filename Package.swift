// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "flashcheck",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FlashCheckCore", targets: ["FlashCheckCore"]),
        .library(name: "FlashCheckMac", targets: ["FlashCheckMac"]),
        .library(name: "FlashCheckCLI", targets: ["FlashCheckCLI"]),
        .executable(name: "flashcheck", targets: ["flashcheck"]),
    ],
    targets: [
        .target(name: "FlashCheckCore"),
        .target(name: "FlashCheckMac", dependencies: ["FlashCheckCore"], linkerSettings: [.linkedFramework("DiskArbitration"), .linkedFramework("IOKit")]),
        .target(name: "FlashCheckCLI", dependencies: ["FlashCheckCore", "FlashCheckMac"]),
        .executableTarget(name: "flashcheck", dependencies: ["FlashCheckCLI"]),
        .testTarget(name: "FlashCheckCoreTests", dependencies: ["FlashCheckCore"]),
        .testTarget(name: "FlashCheckMacTests", dependencies: ["FlashCheckMac"]),
        .testTarget(name: "FlashCheckCLITests", dependencies: ["FlashCheckCLI"]),
    ],
    swiftLanguageModes: [.v6]
)
