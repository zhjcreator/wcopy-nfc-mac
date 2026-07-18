// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WCopyNFCMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WCopyNFCMac", targets: ["WCopyNFCMac"])
    ],
    targets: [
        .executableTarget(
            name: "WCopyNFCMac",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "WCopyNFCMacTests",
            dependencies: ["WCopyNFCMac"]
        )
    ],
    swiftLanguageModes: [.v5]
)
