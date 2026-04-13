// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Wg0MacApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Wg0MacApp",
            targets: ["Wg0MacApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Wg0MacApp",
            path: "Sources/Wg0MacApp"
        )
    ]
)
