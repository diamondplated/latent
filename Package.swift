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
        .library(name: "PhotoML", targets: ["PhotoML"]),
        .executable(name: "pv-pipeline", targets: ["PipelineCLI"]),
    ],
    targets: [
        .target(
            name: "PipelineCore",
            path: "Sources/PipelineCore"
        ),
        .target(
            name: "EnhancementStages",
            dependencies: ["PipelineCore", "PhotoML"],
            path: "Sources/EnhancementStages"
        ),
        .target(
            name: "PhotoIO",
            dependencies: ["PipelineCore"],
            path: "Sources/PhotoIO"
        ),
        .target(
            name: "PhotoML",
            dependencies: ["PipelineCore"],
            path: "Sources/PhotoML"
        ),
        .executableTarget(
            name: "PipelineCLI",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO", "PhotoML"],
            path: "Sources/PipelineCLI"
        ),
        .testTarget(
            name: "PipelineCoreTests",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO", "PhotoML"],
            path: "Tests/PipelineCoreTests"
        ),
    ]
)
