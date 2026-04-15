// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwallowScreen",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SwallowScreen",
            targets: ["SwallowScreen"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "SwallowScreen",
            dependencies: [],
            path: "SwallowScreen",
            exclude: ["Assets.xcassets"],
            resources: [
                .process("Assets.xcassets"),
                .process("HelpView.html")
            ]
        )
    ]
)
