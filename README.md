# ModelKit

A Swift package for downloading, loading, and managing on-device ML models on Apple platforms (iOS 26+, macOS 26+).

ModelKit is a thin orchestration layer over framework-specific loaders. It bundles a model catalog type, a download/load/delete API, and pluggable loaders for MLX (LLM + VLM) and WhisperKit (speech-to-text). Adding a new model family is a single conformance plus one register call — no edits to core.

## Why this exists

`mlx-swift-lm`, `WhisperKit`, and friends each ship their own download + load APIs with different shapes, different cache layouts, and different ways to express progress. If you want to support more than one in the same app you end up writing the same glue. ModelKit is that glue, factored into a package so you don't have to.

## Products

| Product | Depends on | Use it when |
|---|---|---|
| `ModelKit` | (nothing) | Always — core types, orchestration, registry. No framework deps. |
| `ModelKitMLX` | `ModelKit`, `mlx-swift-lm`, `swift-transformers`, `swift-huggingface` | You want to run LLMs / VLMs via MLX. |
| `ModelKitWhisper` | `ModelKit`, `WhisperKit` | You want speech-to-text via WhisperKit. |

Link only what you need — a Whisper-only app skips `ModelKitMLX` entirely.

## Install

**Local SPM** (during development): *File → Add Package Dependencies → Add Local…* and point at this package directory.

**Remote SPM** (once published): add to your `Package.swift`:

```swift
.package(url: "https://github.com/<you>/ModelKit", from: "0.1.0"),
```

Then add the products you want to your target's dependencies.

## Quick start

1. Register the loader(s) for the kinds you'll use, once at launch:

```swift
import SwiftUI
import ModelKitMLX
import ModelKitWhisper

@main
struct MyApp: App {
    init() {
        ModelKitMLX.register()      // enables .llm and .vlm
        ModelKitWhisper.register()  // enables .whisper
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

2. Define a catalog (app-specific data, not bundled in the package):

```swift
import ModelKit

enum MyCatalog {
    static let all: [ModelEntry] = [
        .init("mlx-community/Llama-3.2-3B-Instruct-4bit", "Llama 3.2 3B", .llm,     1.8, .phone),
        .init("mlx-community/gemma-3-4b-it-qat-4bit",     "Gemma 3 4B Vision", .vlm, 2.8, .tabletOrMac),
        .init("openai_whisper-base.en",                   "Whisper base (En)", .whisper, 0.14, .phone),
    ]
}
```

3. Drive `ModelStore` from your UI (or anything else):

```swift
let store = ModelStore.shared
let entry = MyCatalog.all[0]

store.startDownload(entry)              // snapshot to disk only
await store.load(entry)                 // download (if needed) + into memory
store.unload()
store.delete(entry)
```

`ModelStore` is `@Observable` and `@MainActor` — bind directly to SwiftUI views.

## Concepts

### `ModelKind`
Open value type identifying a model family. Adding a new kind = one new static constant. Built-in: `.llm`, `.vlm`, `.whisper`.

### `ModelKindLoader`
The pluggable boundary. One conformance per family, four methods:

```swift
public protocol ModelKindLoader: Sendable {
    var kind: ModelKind { get }
    func isDownloaded(repoId: String) -> Bool
    func startDownload(repoId: String, progressHandler: @escaping @Sendable (Double) -> Void) async throws
    func load(repoId: String, progressHandler: @escaping @Sendable (Double) -> Void) async throws -> any LoadedModel
    func delete(repoId: String)
}
```

### `LoadedModel`
Type-erased handle returned by `load`. Cast to the concrete wrapper to use the underlying container:

```swift
guard let llm = store.loadedModel as? LLMModel else { return }
let container: ModelContainer = llm.container   // from MLXLMCommon
```

Concrete types per kind: `LLMModel`, `VLMModel` (in `ModelKitMLX`), `WhisperModel` (in `ModelKitWhisper`).

### `ModelStore`
Orchestrator. Knows nothing about MLX or WhisperKit — looks up the right loader in `ModelKindRegistry` and delegates. Per-entry download progress, cancellation, and one loaded model held at a time.

### `ModelStorage.root`
Single on-disk root for every loader's cache. Defaults to `Application Support/ModelKit/models`. Override before any loader runs:

```swift
ModelStorage.customRoot = URL(fileURLWithPath: "/custom/path")
```

## Adding a new kind

Say you want CoreML embeddings:

```swift
// 1. Define the kind
extension ModelKind {
    static let embedding = ModelKind(id: "embedding", label: "Embedding")
}

// 2. Define the loaded-model wrapper
final class EmbeddingModel: LoadedModel {
    let kind = ModelKind.embedding
    let repoId: String
    let model: SomeEmbeddingPipeline
    init(repoId: String, model: SomeEmbeddingPipeline) {
        self.repoId = repoId; self.model = model
    }
}

// 3. Define the loader
struct CoreMLEmbeddingLoader: ModelKindLoader {
    static let shared = CoreMLEmbeddingLoader()
    let kind = ModelKind.embedding
    func isDownloaded(repoId: String) -> Bool { /* … */ }
    func startDownload(repoId: String, progressHandler: ...) async throws { /* … */ }
    func load(repoId: String, progressHandler: ...) async throws -> any LoadedModel { /* … */ }
    func delete(repoId: String) { /* … */ }
}

// 4. Register at launch
ModelKindRegistry.register(CoreMLEmbeddingLoader.shared)
```

`ModelStore`, your catalog, and your UI need no changes — they all go through the registry.

## Storage layout

```
Application Support/ModelKit/models/
├── models/                                  ← HuggingFace cache (MLX kinds)
│   ├── mlx-community/Llama-3.2-3B-Instruct-4bit/
│   │   ├── snapshots/<commit>/...
│   │   └── refs/main
│   └── argmaxinc/whisperkit-coreml/
│       └── openai_whisper-base.en/
│           └── ...
```

Layout matches the Python HF cache, so a system Python install can share files.

## Status

- iOS 26+, macOS 26+
- Swift 6.2
- Built against `mlx-swift-lm` 3.31.3+, `swift-transformers` 1.3+, `swift-huggingface` 0.9.x, `WhisperKit` `main`

## License

TBD.
