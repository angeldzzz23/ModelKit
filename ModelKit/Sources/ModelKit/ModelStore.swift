//
//  ModelStore.swift
//  ModelKit
//

import Foundation
import Observation

/// Orchestrates downloads + loads. One loaded model **per kind** can coexist
/// (e.g. Whisper for STT alongside an LLM for chat). Knows nothing about
/// specific frameworks — delegates everything to the kind-specific loader
/// in its `ModelKindRegistry`.
@MainActor
@Observable
public final class ModelStore {
    /// Per-store registry. Construct it, register loaders into it, hand it here.
    public let registry: ModelKindRegistry

    /// Currently-loaded models, keyed by kind. At most one per kind.
    public private(set) var loadedModels: [ModelKind: any LoadedModel] = [:]

    /// Active downloads keyed by entry.id (`repoId#kind.id`).
    public private(set) var downloadProgress: [String: Double] = [:]
    public private(set) var loadingEntryId: String?
    public private(set) var lastError: String?

    /// Bumped whenever on-disk model state changes (download completes,
    /// load succeeds, delete runs). Views can read this to subscribe to
    /// disk-state changes via `@Observable`, since `isDownloaded(_:)`
    /// itself queries the filesystem and has no observable signal of
    /// its own.
    public private(set) var diskRevision: Int = 0

    private var downloadTasks: [String: Task<Void, Never>] = [:]

    public init(registry: ModelKindRegistry) {
        self.registry = registry
    }

    // MARK: - Lookup

    public func loadedModel(for kind: ModelKind) -> (any LoadedModel)? {
        loadedModels[kind]
    }

    /// Convenience cast: `store.loadedModel(LLMModel.self)`.
    public func loadedModel<T: LoadedModel>(_ type: T.Type) -> T? {
        for model in loadedModels.values {
            if let typed = model as? T { return typed }
        }
        return nil
    }

    public func isLoaded(_ entry: ModelEntry) -> Bool {
        loadedModels[entry.kind]?.repoId == entry.repoId
    }

    public var loadedEntryIds: Set<String> {
        Set(loadedModels.values.map { "\($0.repoId)#\($0.kind.id)" })
    }

    // MARK: - Disk state

    public func isDownloaded(_ entry: ModelEntry) -> Bool {
        registry.loader(for: entry.kind)?.isDownloaded(repoId: entry.repoId) ?? false
    }

    public func isDownloading(_ entry: ModelEntry) -> Bool {
        downloadTasks[entry.id] != nil
    }

    public func progress(for entry: ModelEntry) -> Double? {
        downloadProgress[entry.id]
    }

    // MARK: - Download

    public func startDownload(_ entry: ModelEntry) {
        guard downloadTasks[entry.id] == nil,
              let loader = registry.loader(for: entry.kind) else { return }
        let entryId = entry.id
        let repoId = entry.repoId
        downloadProgress[entryId] = 0
        downloadTasks[entryId] = Task { [loader, weak self] in
            do {
                try await loader.startDownload(repoId: repoId) { fraction in
                    Task { @MainActor in
                        self?.downloadProgress[entryId] = fraction
                    }
                }
                await MainActor.run {
                    self?.downloadProgress.removeValue(forKey: entryId)
                    self?.downloadTasks.removeValue(forKey: entryId)
                    self?.diskRevision &+= 1
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.downloadProgress.removeValue(forKey: entryId)
                    self?.downloadTasks.removeValue(forKey: entryId)
                }
            } catch {
                await MainActor.run {
                    self?.lastError = "Download failed for \(repoId): \(error.localizedDescription)"
                    self?.downloadProgress.removeValue(forKey: entryId)
                    self?.downloadTasks.removeValue(forKey: entryId)
                }
            }
        }
    }

    public func cancelDownload(_ entry: ModelEntry) {
        downloadTasks[entry.id]?.cancel()
    }

    // MARK: - Load / unload

    public func load(_ entry: ModelEntry) async {
        guard loadingEntryId == nil,
              let loader = registry.loader(for: entry.kind) else { return }
        loadingEntryId = entry.id
        // Drop any previous model of this kind before bringing up the new one.
        loadedModels.removeValue(forKey: entry.kind)
        defer { loadingEntryId = nil }

        let entryId = entry.id
        do {
            let model = try await loader.load(repoId: entry.repoId) { [weak self] fraction in
                Task { @MainActor in
                    self?.downloadProgress[entryId] = fraction
                }
            }
            self.downloadProgress.removeValue(forKey: entry.id)
            self.loadedModels[entry.kind] = model
            self.diskRevision &+= 1
        } catch {
            self.lastError = "Load failed for \(entry.repoId): \(error.localizedDescription)"
            self.downloadProgress.removeValue(forKey: entry.id)
        }
    }

    /// Unload the model loaded for the given kind, if any.
    public func unload(_ kind: ModelKind) {
        loadedModels.removeValue(forKey: kind)
    }

    /// Unload a specific entry (only if it's the one currently loaded for its kind).
    public func unload(_ entry: ModelEntry) {
        if loadedModels[entry.kind]?.repoId == entry.repoId {
            loadedModels.removeValue(forKey: entry.kind)
        }
    }

    public func unloadAll() {
        loadedModels.removeAll()
    }

    // MARK: - Delete

    public func delete(_ entry: ModelEntry) {
        unload(entry)
        registry.loader(for: entry.kind)?.delete(repoId: entry.repoId)
        diskRevision &+= 1
    }

    public func clearError() { lastError = nil }
}
