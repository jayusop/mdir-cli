// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mdir-cli",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "mdir",
            targets: ["mdir"]
        )
    ],
    targets: [
        .executableTarget(
            name: "mdir"
        )
    ]
)
