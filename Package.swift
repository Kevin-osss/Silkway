// swift-tools-version: 6.0
//
// 这个 Package 不是最终交付物，而是**编译验证工具**。
//
// Silkway 正式产物是 Silkway.xcodeproj 构建的 macOS App。但 App target 依赖
// SwiftUI / MenuBarExtra，无法在无头环境下快速验证。因此把不依赖 UI 的
// Models / Core / Services / Utils 单独组成一个 library target，
// 用 `swift build` 和 `swift test` 做真实编译与单元测试。
//
// 约束：本 target 内的代码**禁止 import SwiftUI / AppKit 的 UI 部分**，
// 否则失去无头验证能力。颜色、图标等表现层逻辑必须留在 Views/。
//
//   swift build              编译验证
//   swift test               跑单元测试
//
import PackageDescription

let package = Package(
    name: "SilkwayCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SilkwayCore", targets: ["SilkwayCore"])
    ],
    targets: [
        .target(
            name: "SilkwayCore",
            path: "Silkway",
            exclude: ["App", "Views", "Resources", "Utils/Constants.swift"],
            sources: ["Models", "Core", "Services", "Utils"]
        ),
        .testTarget(
            name: "SilkwayCoreTests",
            dependencies: ["SilkwayCore"],
            path: "Tests/SilkwayCoreTests"
        )
    ]
)
