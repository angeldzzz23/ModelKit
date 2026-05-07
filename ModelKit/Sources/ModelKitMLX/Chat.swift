//
//  Chat.swift
//  ModelKitMLX
//
//  Streaming text generation for `.llm` and `.vlm` models. Wraps
//  `MLXLMCommon.generate(...)` (AsyncStream form, 3.31.x+) into an
//  `AsyncStream<String>` of decoded text chunks.
//

import Foundation
@_exported import MLXLMCommon
import MLXLLM
import MLXVLM

/// Conversation turn. Use the static factories to avoid leaking the
/// underlying `MLXLMCommon.Chat.Message` shape across modules.
public struct ChatTurn: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable, Codable {
        case system, user, assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String)    -> ChatTurn { .init(role: .system, content: content) }
    public static func user(_ content: String)      -> ChatTurn { .init(role: .user, content: content) }
    public static func assistant(_ content: String) -> ChatTurn { .init(role: .assistant, content: content) }

    fileprivate var asMLXMessage: Chat.Message {
        switch role {
        case .system:    return .system(content)
        case .user:      return .user(content)
        case .assistant: return .assistant(content)
        }
    }
}

// MARK: - LLM streaming

extension LLMModel {
    /// Stream a reply for the given conversation. Each yielded string is
    /// an already-decoded delta — append to whatever you're displaying.
    public func stream(
        turns: [ChatTurn],
        parameters: GenerateParameters = GenerateParameters()
    ) async throws -> AsyncStream<String> {
        try await Self.streamGeneric(
            container: container,
            turns: turns,
            parameters: parameters
        )
    }
}

// MARK: - VLM streaming

extension VLMModel {
    /// Text-only streaming for VLMs. (Image inputs would extend
    /// `ChatTurn` with attachments — out of scope for v1.)
    public func stream(
        turns: [ChatTurn],
        parameters: GenerateParameters = GenerateParameters()
    ) async throws -> AsyncStream<String> {
        try await VLMModel.streamGeneric(
            container: container,
            turns: turns,
            parameters: parameters
        )
    }
}

// MARK: - Shared implementation

private protocol _ChatStreamable {}
extension LLMModel: _ChatStreamable {}
extension VLMModel: _ChatStreamable {}

extension _ChatStreamable {
    fileprivate static func streamGeneric(
        container: ModelContainer,
        turns: [ChatTurn],
        parameters: GenerateParameters
    ) async throws -> AsyncStream<String> {
        return try await container.perform { (context: ModelContext) in
            let userInput = UserInput(chat: turns.map(\.asMLXMessage))
            let lmInput = try await context.processor.prepare(input: userInput)
            let upstream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            )
            return AsyncStream<String> { continuation in
                let task = Task {
                    for await event in upstream {
                        if Task.isCancelled { break }
                        if case .chunk(let text) = event {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
