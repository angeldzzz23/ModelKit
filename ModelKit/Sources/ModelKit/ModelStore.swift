//
//  ModelStore.swift
//  ModelKit
//

import Foundation
import Observation

/// Orchestrates downloads + loads. Knows nothing about specific frameworks —
/// delegates everything to the kind-specific loader registered in
/// `ModelKindRegistry`. Adding a new kind is a no-op for this file.
@MainActor
@Observable
public final class ModelStore {
    public static let shared = ModelStore()

    // Currently-loaded model.
    public private(set) var loadedModel: (any LoadedModel)?
    public var loadedEntryId: String? {
        guard let m = loadedModel else { return nil }
        return "\(m.repoId)#\(m.kind.id)"
    }

    // Active downloads keyed by entry.id (`repoId#kind.id`).
    public private(set) var downloadProgress: [String: Double] = [:]
    public private(set) var loadingEntryId: String?
    public private(set) var lastError: String?

    private var downloadTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    // MARK: - Disk state

    public func isDownloaded(_ entry: ModelEntry) -> Bool {
        ModelKindRegistry.loader(for: entry.kind)?.isDownloaded(repoId: entry.repoId) ?? false
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
              let loader = ModelKindRegistry.loader(for: entry.kind) else { return }
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
              let loader = ModelKindRegistry.loader(for: entry.kind) else { return }
        loadingEntryId = entry.id
        loadedModel = nil
        defer { loadingEntryId = nil }

        let entryId = entry.id
        do {
            let model = try await loader.load(repoId: entry.repoId) { [weak self] fraction in
                Task { @MainActor in
                    self?.downloadProgress[entryId] = fraction
                }
            }
            self.downloadProgress.removeValue(forKey: entry.id)
            self.loadedModel = model
        } catch {
            self.lastError = "Load failed for \(entry.repoId): \(error.localizedDescription)"
            self.downloadProgress.removeValue(forKey: entry.id)
        }
    }

    public func unload() {
        loadedModel = nil
    }

    // MARK: - Delete

    public func delete(_ entry: ModelEntry) {
        if loadedModel?.repoId == entry.repoId, loadedModel?.kind == entry.kind {
            unload()
        }
        ModelKindRegistry.loader(for: entry.kind)?.delete(repoId: entry.repoId)
    }

    public func clearError() { lastError = nil }
}
