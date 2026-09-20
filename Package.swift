// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleNano",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "apple-nano", targets: ["AppleNano"])
    ],
    targets: [
        .executableTarget(name: "AppleNano")
    ]
)
