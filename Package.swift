// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenshotTool",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ScreenshotTool", targets: ["ScreenshotTool"])
    ],
    targets: [
        .target(
            name: "LongScreenshotCore"
        ),
        .target(
            name: "ScreenshotToolbarCore"
        ),
        .executableTarget(
            name: "ScreenshotTool",
            dependencies: ["LongScreenshotCore", "ScreenshotToolbarCore"],
            exclude: ["Info.plist", "Entitlements.plist", "AppIcon.icns"]
        ),
        .executableTarget(
            name: "LongScreenshotCoreChecks",
            dependencies: ["LongScreenshotCore"],
            path: "Tests/ScreenshotToolTests"
        ),
        .executableTarget(
            name: "LongScreenshotImageChecks",
            dependencies: ["LongScreenshotCore"],
            path: "Tests/LongScreenshotImageChecks"
        ),
        .executableTarget(
            name: "ScreenshotToolbarChecks",
            dependencies: ["ScreenshotToolbarCore"],
            path: "Tests/ScreenshotToolbarChecks"
        )
    ]
)
