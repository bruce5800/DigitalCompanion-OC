// swift-tools-version:6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RealityKitContent",
    platforms: [
        .visionOS(.v26),
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "RealityKitContent",
            targets: ["RealityKitContent"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "RealityKitContent",
            dependencies: [],
            resources: [
                // 三个角色的"共享几何 + 薄动画层"资产集(每角色一个文件夹整体拷贝):
                //   {c}/{c}_idle.usdc         全量文件(几何+材质+骨架+idle 动画)
                //   {c}/{c}_{clip}.usdc ×11   薄层(sublayer 引用 idle,仅覆写骨骼动画)
                //   {c}/{c}_XX.png            共享贴图
                // 由 tools/vroid_pipeline/05_make_thin_set.py 从全量 USDZ 集生成。
                .copy("oc"),
                .copy("sg"),
                .copy("xo"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility")
            ]),
    ]
)
