//
//  ModelEntry.swift
//  ModelKit
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Open value type so adding a new kind (Whisper, embeddings, diffusion, …)
/// is one new static constant + one loader registration. No enum switches.
public struct ModelKind: Hashable, Sendable, Codable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    public static let llm     = ModelKind(id: "llm",     label: "LLM")
    public static let vlm     = ModelKind(id: "vlm",     label: "Vision")
    public static let whisper = ModelKind(id: "whisper", label: "Speech")
}

public enum DeviceTier: Int, Comparable, Codable, Sendable {
    case phone = 0
    case tabletOrMac = 1
    case bigMac = 2

    public static func < (lhs: DeviceTier, rhs: DeviceTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .phone: "iPhone / iPad"
        case .tabletOrMac: "iPad Pro / Mac"
        case .bigMac: "Mac (16GB+)"
        }
    }
}

public struct ModelEntry: Identifiable, Hashable, Sendable {
    public let repoId: String
    public let displayName: String
    public let kind: ModelKind
    public let approxSizeGB: Double
    public let minTier: DeviceTier
    public let note: String?

    public var id: String { "\(repoId)#\(kind.id)" }

    public init(
        _ repoId: String,
        _ displayName: String,
        _ kind: ModelKind,
        _ approxSizeGB: Double,
        _ minTier: DeviceTier,
        note: String? = nil
    ) {
        self.repoId = repoId
        self.displayName = displayName
        self.kind = kind
        self.approxSizeGB = approxSizeGB
        self.minTier = minTier
        self.note = note
    }
}

/// Shared on-disk root for every kind's downloads.
/// Override `customRoot` before any loader is used to redirect storage.
public enum ModelStorage {
    public nonisolated(unsafe) static var customRoot: URL?

    public static var root: URL {
        if let customRoot { return customRoot }
        return defaultRoot
    }

    private static let defaultRoot: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = support.appendingPathComponent("ModelKit/models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

public enum Device {
    public static var currentTier: DeviceTier {
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        #if os(macOS)
        if ramGB >= 32 { return .bigMac }
        if ramGB >= 12 { return .tabletOrMac }
        return .phone
        #else
        if ramGB >= 12 { return .tabletOrMac }
        return .phone
        #endif
    }

    public static var ramGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    public static var summary: String {
        let gb = String(format: "%.0f", ramGB)
        #if os(macOS)
        return "Mac · \(gb) GB"
        #else
        return "\(UIDevice.current.model) · \(gb) GB"
        #endif
    }
}
