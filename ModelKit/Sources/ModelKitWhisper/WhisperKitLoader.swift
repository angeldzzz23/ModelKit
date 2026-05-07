//
//  WhisperKitLoader.swift
//  ModelKitWhisper
//
//  WhisperKit-backed loader for `.whisper` kind. WhisperKit ships its own
//  HF-style downloader (HubApiWrapper) so we use it directly. For Whisper
//  entries the `repoId` field stores the variant name
//  (e.g. "openai_whisper-base.en"); the source repo is the WhisperKit
//  catalog "argmaxinc/whisperkit-coreml".
//

import Foundation
import WhisperKit
import ModelKit

public final class WhisperModel: LoadedModel, @unchecked Sendable {
    public let kind = ModelKind.whisper
    public let repoId: String
    public let pipeline: WhisperKit
    public init(repoId: String, pipeline: WhisperKit) {
        self.repoId = repoId
        self.pipeline = pipeline
    }
}

public struct WhisperKitLoader: ModelKindLoader {
    public static let shared = WhisperKitLoader()
    public let kind = ModelKind.whisper

    /// Override before first use to point at a different WhisperKit fork.
    public nonisolated(unsafe) static var modelRepo: String = "argmaxinc/whisperkit-coreml"

    private func modelFolder(variant: String) -> URL {
        // HubApiWrapper uses `<downloadBase>/<repoType>/<repo.id>/…` where
        // repoType for models is "models". Variants live as subfolders.
        ModelStorage.root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.modelRepo, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    public func isDownloaded(repoId: String) -> Bool {
        let folder = modelFolder(variant: repoId)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return !entries.isEmpty
    }

    public func startDownload(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: repoId,
            downloadBase: ModelStorage.root,
            from: Self.modelRepo,
            progressCallback: { progress in
                progressHandler(progress.fractionCompleted)
            }
        )
    }

    public func load(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> any LoadedModel {
        let config = WhisperKitConfig(
            model: repoId,
            downloadBase: ModelStorage.root,
            modelRepo: Self.modelRepo,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        )
        let pipeline = try await WhisperKit(config)
        progressHandler(1.0)
        return WhisperModel(repoId: repoId, pipeline: pipeline)
    }

    public func delete(repoId: String) {
        let folder = modelFolder(variant: repoId)
        try? FileManager.default.removeItem(at: folder)
    }
}

public enum ModelKitWhisper {
    @MainActor
    public static func register() {
        ModelKindRegistry.register(WhisperKitLoader.shared)
    }
}
