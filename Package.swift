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
        .library(name: "PhotoSearch", targets: ["PhotoSearch"]),
        .library(name: "PhotoViewerCore", targets: ["PhotoViewerCore"]),
        .library(name: "PhotoGeo", targets: ["PhotoGeo"]),
        .executable(name: "pv-pipeline", targets: ["PipelineCLI"]),
        .executable(name: "PhotoViewerApp", targets: ["PhotoViewerApp"]),
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
        .target(
            name: "PhotoSearch",
            dependencies: ["PipelineCore", "PhotoIO", "PhotoML"],
            path: "Sources/PhotoSearch"
        ),
        .target(
            name: "PhotoViewerCore",
            dependencies: [],
            path: "Sources/PhotoViewerCore"
        ),
        .target(
            name: "PhotoGeo",
            dependencies: ["PipelineCore", "PhotoIO"],
            path: "Sources/PhotoGeo"
        ),
        .executableTarget(
            name: "PipelineCLI",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO", "PhotoML", "PhotoSearch", "PhotoViewerCore", "PhotoGeo"],
            path: "Sources/PipelineCLI"
        ),
        .executableTarget(
            name: "PhotoViewerApp",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO", "PhotoML", "PhotoViewerCore", "PhotoGeo"],
            path: "Sources/PhotoViewerApp"
        ),
        .testTarget(
            name: "PipelineCoreTests",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO", "PhotoML", "PhotoSearch"],
            path: "Tests/PipelineCoreTests"
        ),
    ]
)
