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
        // 纯逻辑核心：仅含无 UI 依赖的源文件，供单元测试独立编译
        // （GUI 主模块含 SwiftData/@Preview，swift test 在本机 SDK 下无法编译）
        .target(
            name: "SwallowScreenCore",
            path: "SwallowScreen",
            sources: ["UpdateChannel.swift"]
        ),
        .executableTarget(
            name: "SwallowScreen",
            dependencies: ["SwallowScreenCore"],
            path: "SwallowScreen",
            exclude: ["Assets.xcassets", "UpdateChannel.swift"],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        // 更新渠道等纯逻辑的单元测试（swift test 运行；Xcode 工程不含此目录）
        .testTarget(
            name: "SwallowScreenTests",
            dependencies: ["SwallowScreenCore"],
            path: "Tests/SwallowScreenTests"
        )
    ]
)
