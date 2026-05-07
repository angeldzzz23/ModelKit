// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ModelKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ModelKit",        targets: ["ModelKit"]),
        .library(name: "ModelKitMLX",     targets: ["ModelKitMLX"]),
        .library(name: "ModelKitWhisper", targets: ["ModelKitWhisper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm",         from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers",  from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface",   "0.9.0" ..< "1.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git",        branch: "main"),
    ],
    targets: [
        // Pure Swift core: types + orchestration. No framework deps.
        .target(
            name: "ModelKit"
        ),

        // MLX-backed loaders for `.llm` and `.vlm`.
        .target(
            name: "ModelKitMLX",
            dependencies: [
                "ModelKit",
                .product(name: "MLXLLM",         package: "mlx-swift-lm"),
                .product(name: "MLXVLM",         package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon",    package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers",     package: "swift-transformers"),
                .product(name: "HuggingFace",    package: "swift-huggingface"),
            ]
        ),

        // WhisperKit-backed loader for `.whisper`.
        .target(
            name: "ModelKitWhisper",
            dependencies: [
                "ModelKit",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
    ]
)
