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
