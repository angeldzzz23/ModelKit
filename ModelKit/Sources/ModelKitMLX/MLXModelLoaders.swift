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

/// HubClient + cache for HuggingFace-backed loaders (LLM, VLM, future
/// embeddings, …). One instance per cache root — share it across the
/// HF-backed loaders you register so they hit the same cache.
public final class MLXHuggingFaceBackend: @unchecked Sendable {
    public let cache: HubCache
    public let client: HubClient

    public init(root: URL = ModelStorage.root) {
        let cache = HubCache(cacheDirectory: root)
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
    public let kind = ModelKind.llm
    public let backend: MLXHuggingFaceBackend

    public init(backend: MLXHuggingFaceBackend) {
        self.backend = backend
    }

    public func isDownloaded(repoId: String) -> Bool {
        backend.isDownloaded(repoId: repoId)
    }

    public func startDownload(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await backend.snapshot(repoId: repoId, progress: progressHandler)
    }

    public func load(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> any LoadedModel {
        let client = backend.client
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
        backend.delete(repoId: repoId)
    }
}

// MARK: - VLM loader

public struct MLXVLMLoader: ModelKindLoader {
    public let kind = ModelKind.vlm
    public let backend: MLXHuggingFaceBackend

    public init(backend: MLXHuggingFaceBackend) {
        self.backend = backend
    }

    public func isDownloaded(repoId: String) -> Bool {
        backend.isDownloaded(repoId: repoId)
    }

    public func startDownload(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await backend.snapshot(repoId: repoId, progress: progressHandler)
    }

    public func load(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> any LoadedModel {
        let client = backend.client
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
        backend.delete(repoId: repoId)
    }
}

// MARK: - Convenience entry point

public enum ModelKitMLX {
    /// Construct an `MLXHuggingFaceBackend(root:)` and register both MLX
    /// loaders into the supplied registry.
    @MainActor
    public static func register(
        into registry: ModelKindRegistry,
        root: URL = ModelStorage.root
    ) {
        let backend = MLXHuggingFaceBackend(root: root)
        registry.register(MLXLLMLoader(backend: backend))
        registry.register(MLXVLMLoader(backend: backend))
    }
}
