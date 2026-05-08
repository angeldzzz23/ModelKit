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
    /// entry.ids currently mid-load. Multiple loads can run concurrently —
    /// the per-kind cap (one model per kind in `loadedModels`) is enforced
    /// at completion: whichever load finishes last wins for that kind.
    public private(set) var loadingEntryIds: Set<String> = []
    public private(set) var lastError: String?

    /// Consumer-supplied list of entries to auto-load on
    /// `loadDefaults()`. Mutate freely at runtime.
    public var defaults: [ModelEntry] = []

    /// Bumped whenever on-disk model state changes (download completes,
    /// load succeeds, delete runs). Views can read this to subscribe to
    /// disk-state changes via `@Observable`, since `isDownloaded(_:)`
    /// itself queries the filesystem and has no observable signal of
    /// its own.
    public private(set) var diskRevision: Int = 0

    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var eventContinuations: [UUID: AsyncStream<ModelStoreEvent>.Continuation] = [:]

    public init(registry: ModelKindRegistry) {
        self.registry = registry
    }

    // MARK: - Event stream

    /// Long-lived stream of state-change events. Returns a fresh stream
    /// per call so multiple subscribers can run concurrently. Each
    /// subscription is automatically cleaned up when the consumer's task
    /// is cancelled.
    public func events() -> AsyncStream<ModelStoreEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { @MainActor [weak self] in
                self?.eventContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func emit(_ event: ModelStoreEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
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

    public func isLoading(_ entry: ModelEntry) -> Bool {
        loadingEntryIds.contains(entry.id)
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
        emit(.downloadStarted(entry))
        downloadTasks[entryId] = Task { [loader, weak self, entry] in
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
                    self?.emit(.downloadFinished(entry))
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.downloadProgress.removeValue(forKey: entryId)
                    self?.downloadTasks.removeValue(forKey: entryId)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self?.lastError = "Download failed for \(repoId): \(message)"
                    self?.downloadProgress.removeValue(forKey: entryId)
                    self?.downloadTasks.removeValue(forKey: entryId)
                    self?.emit(.downloadFailed(entry, message: message))
                }
            }
        }
    }

    public func cancelDownload(_ entry: ModelEntry) {
        downloadTasks[entry.id]?.cancel()
    }

    // MARK: - Load / unload

    public func load(_ entry: ModelEntry) async {
        guard !loadingEntryIds.contains(entry.id),
              let loader = registry.loader(for: entry.kind) else { return }
        loadingEntryIds.insert(entry.id)
        // Drop any previous model of this kind before bringing up the new one.
        loadedModels.removeValue(forKey: entry.kind)
        defer { loadingEntryIds.remove(entry.id) }

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
            self.emit(.loaded(entry))
        } catch {
            self.lastError = "Load failed for \(entry.repoId): \(error.localizedDescription)"
            self.downloadProgress.removeValue(forKey: entry.id)
            self.emit(.loadFailed(entry, message: error.localizedDescription))
        }
    }

    /// Concurrently `load(_:)` every entry in `defaults`. `load(_:)` is
    /// idempotent on its own (no-op if already loaded or mid-load), so
    /// repeat calls are safe.
    public func loadDefaults() async {
        let snapshot = defaults
        await withTaskGroup(of: Void.self) { group in
            for entry in snapshot {
                group.addTask { [weak self] in
                    await self?.load(entry)
                }
            }
        }
    }

    /// Unload the model loaded for the given kind, if any.
    public func unload(_ kind: ModelKind) {
        guard loadedModels[kind] != nil else { return }
        loadedModels.removeValue(forKey: kind)
        emit(.unloaded(kind))
    }

    /// Unload a specific entry (only if it's the one currently loaded for its kind).
    public func unload(_ entry: ModelEntry) {
        if loadedModels[entry.kind]?.repoId == entry.repoId {
            loadedModels.removeValue(forKey: entry.kind)
            emit(.unloaded(entry.kind))
        }
    }

    public func unloadAll() {
        let kinds = Array(loadedModels.keys)
        loadedModels.removeAll()
        for kind in kinds {
            emit(.unloaded(kind))
        }
    }

    // MARK: - Delete

    public func delete(_ entry: ModelEntry) {
        unload(entry)
        registry.loader(for: entry.kind)?.delete(repoId: entry.repoId)
        diskRevision &+= 1
        emit(.deleted(entry))
    }

    public func clearError() { lastError = nil }
}
