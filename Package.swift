// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwallowScreen",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SwallowScreen",
            targets: ["SwallowScreen"],
            type: .application,
            plistOptions: .init(
                path: "SwallowScreen/Info.plist",
                generate: false
            )
        )
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
