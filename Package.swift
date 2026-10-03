// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "tidy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "tidy",
            path: "Sources/tidy"
        ),
        .testTarget(
            name: "tidyTests",
            dependencies: ["tidy"],
            path: "Tests/tidyTests"
        )
    ]
)
