//
//  MLXModelLoaders.swift
//  ModelKitMLX
//
//  MLX-backed loaders for `.llm` and `.vlm` kinds. Both delegate to the
//  same swift-huggingface `HubClient` — only the in-memory factory differs.
//

import Foundation
import HuggingFace
import Tokenizers
import MLXLLM
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import ModelKit

// MARK: - Loaded model wrappers

public final class LLMModel: LoadedModel {
    public let kind = ModelKind.llm
    public let repoId: String
    public let container: ModelContainer
    public init(repoId: String, container: ModelContainer) {
        self.repoId = repoId
        self.container = container
    }
}

public final class VLMModel: LoadedModel {
    public let kind = ModelKind.vlm
    public let repoId: String
    public let container: ModelContainer
    public init(repoId: String, container: ModelContainer) {
        self.repoId = repoId
        self.container = container
    }
}

// MARK: - Shared HF infrastructure

/// HubClient + cache shared by every HuggingFace-backed loader (LLM, VLM,
/// future embeddings, …). Single source of truth for the cache directory.
public final class MLXHuggingFaceBackend: @unchecked Sendable {
    public static let shared = MLXHuggingFaceBackend()

    public let cache: HubCache
    public let client: HubClient

    private init() {
        let cache = HubCache(cacheDirectory: ModelStorage.root)
        self.cache = cache
        self.client = HubClient(cache: cache)
    }

    public func isDownloaded(repoId: String) -> Bool {
        guard let id = Repo.ID(rawValue: repoId) else { return false }
        let dir = cache.snapshotsDirectory(repo: id, kind: .model)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !entries.isEmpty
    }

    public func snapshot(
        repoId: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let id = Repo.ID(rawValue: repoId) else { return }
        _ = try await client.downloadSnapshot(
            of: id,
            matching: [
                "*.json",
                "*.safetensors",
                "*.txt",
                "*.model",
                "*.tiktoken",
                "tokenizer.*",
                "*.py",
            ]
        ) { @MainActor p in
            progress(p.fractionCompleted)
        }
    }

    public func delete(repoId: String) {
        guard let id = Repo.ID(rawValue: repoId) else { return }
        let dir = cache.repoDirectory(repo: id, kind: .model)
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - LLM loader

public struct MLXLLMLoader: ModelKindLoader {
    public static let shared = MLXLLMLoader()
    public let kind = ModelKind.llm

    public func isDownloaded(repoId: String) -> Bool {
        MLXHuggingFaceBackend.shared.isDownloaded(repoId: repoId)
    }

    public func startDownload(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await MLXHuggingFaceBackend.shared.snapshot(repoId: repoId, progress: progressHandler)
    }

    public func load(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> any LoadedModel {
        let client = MLXHuggingFaceBackend.shared.client
        let container = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(client),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: repoId)
        ) { progress in
            progressHandler(progress.fractionCompleted)
        }
        return LLMModel(repoId: repoId, container: container)
    }

    public func delete(repoId: String) {
        MLXHuggingFaceBackend.shared.delete(repoId: repoId)
    }
}

// MARK: - VLM loader

public struct MLXVLMLoader: ModelKindLoader {
    public static let shared = MLXVLMLoader()
    public let kind = ModelKind.vlm

    public func isDownloaded(repoId: String) -> Bool {
        MLXHuggingFaceBackend.shared.isDownloaded(repoId: repoId)
    }

    public func startDownload(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await MLXHuggingFaceBackend.shared.snapshot(repoId: repoId, progress: progressHandler)
    }

    public func load(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> any LoadedModel {
        let client = MLXHuggingFaceBackend.shared.client
        let container = try await VLMModelFactory.shared.loadContainer(
            from: #hubDownloader(client),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: repoId)
        ) { progress in
            progressHandler(progress.fractionCompleted)
        }
        return VLMModel(repoId: repoId, container: container)
    }

    public func delete(repoId: String) {
        MLXHuggingFaceBackend.shared.delete(repoId: repoId)
    }
}

// MARK: - Convenience entry point

public enum ModelKitMLX {
    @MainActor
    public static func register() {
        ModelKindRegistry.register(MLXLLMLoader.shared)
        ModelKindRegistry.register(MLXVLMLoader.shared)
    }
}
