//
//  ModelStoreEvent.swift
//  ModelKit
//
//  State-change events emitted by `ModelStore.events()`. Subscribe from
//  any context (SwiftUI, view models, services, CLI, …) to react to the
//  download/load lifecycle without polling `@Observable` state.
//

import Foundation

public enum ModelStoreEvent: Sendable {
    case downloadStarted(ModelEntry)
    case downloadFinished(ModelEntry)
    case downloadFailed(ModelEntry, message: String)
    case loaded(ModelEntry)
    case loadFailed(ModelEntry, message: String)
    case unloaded(ModelKind)
    case deleted(ModelEntry)

    /// Stable case identifier — branch on this without unwrapping
    /// associated values.
    public enum EventType: String, Sendable {
        case downloadStarted, downloadFinished, downloadFailed
        case loaded, loadFailed
        case unloaded, deleted
    }
}

public extension ModelStoreEvent {
    /// Which kind of event this is. Always available.
    var type: EventType {
        switch self {
        case .downloadStarted:  .downloadStarted
        case .downloadFinished: .downloadFinished
        case .downloadFailed:   .downloadFailed
        case .loaded:           .loaded
        case .loadFailed:       .loadFailed
        case .unloaded:         .unloaded
        case .deleted:          .deleted
        }
    }

    /// The associated `ModelEntry`, if any. `nil` only for `.unloaded`,
    /// which carries a `ModelKind` instead.
    var entry: ModelEntry? {
        switch self {
        case .downloadStarted(let e),
             .downloadFinished(let e),
             .downloadFailed(let e, _),
             .loaded(let e),
             .loadFailed(let e, _),
             .deleted(let e):
            return e
        case .unloaded:
            return nil
        }
    }

    /// The `ModelKind`. Always available — taken from `entry.kind` for
    /// entry-bearing events, or directly from `.unloaded(ModelKind)`.
    var modelKind: ModelKind {
        switch self {
        case .unloaded(let k): return k
        case .downloadStarted(let e),
             .downloadFinished(let e),
             .downloadFailed(let e, _),
             .loaded(let e),
             .loadFailed(let e, _),
             .deleted(let e):
            return e.kind
        }
    }

    /// Populated for `*Failed` events; `nil` otherwise.
    var errorMessage: String? {
        switch self {
        case .downloadFailed(_, let m), .loadFailed(_, let m): return m
        default: return nil
        }
    }
}

extension ModelStoreEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .downloadStarted(let e):       "downloadStarted(\(e.repoId))"
        case .downloadFinished(let e):      "downloadFinished(\(e.repoId))"
        case .downloadFailed(let e, let m): "downloadFailed(\(e.repoId), \(m))"
        case .loaded(let e):                "loaded(\(e.repoId))"
        case .loadFailed(let e, let m):     "loadFailed(\(e.repoId), \(m))"
        case .unloaded(let kind):           "unloaded(\(kind.id))"
        case .deleted(let e):               "deleted(\(e.repoId))"
        }
    }
}
