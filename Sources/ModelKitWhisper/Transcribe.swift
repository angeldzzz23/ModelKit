//
//  Transcribe.swift
//  ModelKitWhisper
//
//  Convenience inference for `.whisper`: audio file → text.
//

import Foundation
import WhisperKit

public enum TranscribeError: Error, LocalizedError {
    case noResult
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case .noResult: "Whisper produced no output."
        case .underlying(let err): err.localizedDescription
        }
    }
}

extension WhisperModel {
    /// Transcribe an audio file. Supports any format WhisperKit accepts
    /// (m4a, wav, mp3, …). Returns the joined text of all segments.
    public func transcribe(audioURL: URL) async throws -> String {
        let results = await pipeline.transcribeWithResults(
            audioPaths: [audioURL.path],
            decodeOptions: nil,
            callback: nil
        )
        guard let first = results.first else { throw TranscribeError.noResult }
        switch first {
        case .success(let segments):
            let text = segments.map(\.text).joined()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure(let error):
            throw TranscribeError.underlying(error)
        }
    }
}
