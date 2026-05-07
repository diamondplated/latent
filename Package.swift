// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoViewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PipelineCore", targets: ["PipelineCore"]),
        .library(name: "EnhancementStages", targets: ["EnhancementStages"]),
        .library(name: "PhotoIO", targets: ["PhotoIO"]),
        .executable(name: "pv-pipeline", targets: ["PipelineCLI"]),
    ],
    targets: [
        .target(
            name: "PipelineCore",
            path: "Sources/PipelineCore"
        ),
        .target(
            name: "EnhancementStages",
            dependencies: ["PipelineCore"],
            path: "Sources/EnhancementStages"
        ),
        .target(
            name: "PhotoIO",
            dependencies: ["PipelineCore"],
            path: "Sources/PhotoIO"
        ),
        .executableTarget(
            name: "PipelineCLI",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO"],
            path: "Sources/PipelineCLI"
        ),
        .testTarget(
            name: "PipelineCoreTests",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO"],
            path: "Tests/PipelineCoreTests"
        ),
    ]
)
