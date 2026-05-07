//
//  ModelKindLoader.swift
//  ModelKit
//

import Foundation

/// Type-erased loaded-model handle. Concrete types own the underlying
/// container (e.g. MLX `ModelContainer`, WhisperKit instance, …).
public protocol LoadedModel: AnyObject, Sendable {
    var kind: ModelKind { get }
    var repoId: String { get }
}

/// Pluggable per-kind I/O. One conformance per model family.
/// Adding a new family ⇒ add a conformance + register it. No edits elsewhere.
public protocol ModelKindLoader: Sendable {
    var kind: ModelKind { get }

    func isDownloaded(repoId: String) -> Bool

    /// Snapshot to disk only, no in-memory load.
    func startDownload(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Download (if needed) + bring into memory.
    func load(
        repoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> any LoadedModel

    func delete(repoId: String)
}

/// Maps `ModelKind` → loader. Loaders register at startup
/// (e.g. `ModelKitMLX.register()`).
@MainActor
public enum ModelKindRegistry {
    private static var loaders: [ModelKind: any ModelKindLoader] = [:]

    public static func register(_ loader: any ModelKindLoader) {
        loaders[loader.kind] = loader
    }

    public static func loader(for kind: ModelKind) -> (any ModelKindLoader)? {
        loaders[kind]
    }

    public static var registeredKinds: [ModelKind] {
        Array(loaders.keys)
    }
}
