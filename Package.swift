// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KurBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "KurBar", path: "Sources/KurBar")
    ]
)
