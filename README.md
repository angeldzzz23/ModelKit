# ModelKit

> One API for downloading, loading, and managing on-device ML models on Apple platforms — across MLX, WhisperKit, and whatever you plug in next.

`mlx-swift-lm`, `WhisperKit`, and friends each ship their own download + load APIs with different shapes, different cache layouts, and different ways to express progress. If you support more than one in the same app you end up writing the same glue. ModelKit is that glue, factored into a package.

## What you get

- **`ModelStore`** — `@Observable @MainActor` orchestrator. Bind it to SwiftUI; it surfaces per-entry download progress, load state, and errors as observable state.
- **MLX (`.llm`, `.vlm`) and WhisperKit (`.whisper`) loaders**, ready to register.
- **Concurrent loads + per-kind cap.** Whisper alongside an LLM alongside a VLM, all in memory at once. Loading a second LLM replaces the first.
- **Default-model auto-load.** Set `store.defaults`, call `await store.loadDefaults()` at startup; the store fans the loads out concurrently.
- **Open `ModelKind`.** Add a new family with one conformance + one register call. No core edits.
- **Single shared on-disk root** at `Application Support/ModelKit/models/` (overridable). HF-compatible layout, so a system Python install can share files.

## Products

| Product | Depends on | Use it when |
|---|---|---|
| `ModelKit` | (nothing) | Always — types + orchestration. Zero framework deps. |
| `ModelKitMLX` | `ModelKit`, `mlx-swift-lm`, `swift-transformers`, `swift-huggingface` | LLMs / VLMs via MLX. |
| `ModelKitWhisper` | `ModelKit`, `WhisperKit` | Speech-to-text via WhisperKit. |

A Whisper-only app links `ModelKit` + `ModelKitWhisper` and skips MLX entirely — and its transitive deps.

## Install

**Local SPM** (during development): *Xcode → File → Add Package Dependencies → Add Local…* and point at this directory.

**Remote SPM** (once published):

```swift
.package(url: "https://github.com/<you>/ModelKit", from: "0.1.0"),
```

Then add `ModelKit` plus whichever loaders you need (`ModelKitMLX`, `ModelKitWhisper`) to your target's dependencies.

## 30-second example

```swift
import SwiftUI
import ModelKit
import ModelKitMLX
import ModelKitWhisper

// 1. Catalog — app-specific, not bundled in the package.
enum Catalog {
    static let all: [ModelEntry] = [
        .init("mlx-community/Llama-3.2-3B-Instruct-4bit", "Llama 3.2 3B", .llm,     1.8, .phone),
        .init("openai_whisper-tiny.en",                   "Whisper Tiny", .whisper, 0.04, .phone),
    ]
}

// 2. Build a registry, register loaders, hand it to the store.
@main
struct MyApp: App {
    @State private var store: ModelStore

    init() {
        let registry = ModelKindRegistry()
        ModelKitMLX.register(into: registry)      // .llm + .vlm
        ModelKitWhisper.register(into: registry)  // .whisper
        _store = State(initialValue: ModelStore(registry: registry))
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environment(store)
        }
    }
}

// 3. Drive it from a view.
struct ContentView: View {
    @Environment(ModelStore.self) private var store

    var body: some View {
        let entry = Catalog.all[0]
        VStack {
            if let p = store.progress(for: entry) {
                ProgressView(value: p)
            }
            Button("Download") { store.startDownload(entry) }
            Button("Load")     { Task { await store.load(entry) } }
            Button("Delete")   { store.delete(entry) }
        }
    }
}
```

`store` is `@Observable` — every read above (`progress(for:)`, etc.) participates in observation tracking. Mutate from anywhere; views re-render automatically.

## Concepts

### `ModelKind`

Open value type identifying a family. Adding a new kind = one static constant.

```swift
public extension ModelKind {
    static let embedding = ModelKind(id: "embedding", label: "Embedding")
}
```

Built-in: `.llm`, `.vlm`, `.whisper`.

### `ModelKindLoader`

The pluggable boundary. One conformance per family:

```swift
public protocol ModelKindLoader: Sendable {
    var kind: ModelKind { get }
    func isDownloaded(repoId: String) -> Bool
    func startDownload(repoId: String, progressHandler: @escaping @Sendable (Double) -> Void) async throws
    func load(repoId: String, progressHandler: @escaping @Sendable (Double) -> Void) async throws -> any LoadedModel
    func delete(repoId: String)
}
```

### `ModelKindRegistry`

A `@MainActor` instance. Construct one, register loaders into it, hand it to a `ModelStore`. One registry per store keeps lookups isolated and makes tests trivial.

```swift
let registry = ModelKindRegistry()
ModelKitMLX.register(into: registry)            // bundles MLXLLMLoader + MLXVLMLoader
ModelKitWhisper.register(into: registry)        // bundles WhisperKitLoader
let store = ModelStore(registry: registry)
```

### `ModelStore`

The orchestrator. Knows nothing about MLX or WhisperKit — looks up the right loader and delegates. State (all observable):

| Property | Purpose |
|---|---|
| `loadedModels: [ModelKind: any LoadedModel]` | currently-loaded models — one per kind |
| `loadingEntryIds: Set<String>` | mid-load entry.ids — concurrent loads supported |
| `downloadProgress: [String: Double]` | active downloads keyed by `entry.id` |
| `lastError: String?` | most recent failure message |
| `diskRevision: Int` | bumps on download/load/delete; observe to refresh disk-derived UI |
| `defaults: [ModelEntry]` | consumer-set; loaded by `loadDefaults()` |

Action surface:

```swift
store.startDownload(entry)             // disk only; progress in store.downloadProgress
store.cancelDownload(entry)
await store.load(entry)                // download if needed + bring into memory
store.unload(entry)                    // free memory, keep on disk
store.delete(entry)                    // remove from disk
await store.loadDefaults()             // concurrent load of every entry in store.defaults
```

`load(_:)` is idempotent — calling it for an entry that's already loaded or mid-load is a no-op.

### `LoadedModel`

Type-erased handle. Cast to the concrete wrapper to use the underlying container:

```swift
guard let llm = store.loadedModels[.llm] as? LLMModel else { return }
let container: ModelContainer = llm.container   // from MLXLMCommon
```

Concrete wrappers: `LLMModel`, `VLMModel` (in `ModelKitMLX`), `WhisperModel` (in `ModelKitWhisper`).

### `ModelStorage.root`

Single on-disk root for every loader's cache. Override **before** any loader runs:

```swift
ModelStorage.customRoot = URL(fileURLWithPath: "/custom/path")
```

## Default models

```swift
store.defaults = [Catalog.all[0], Catalog.all[1]]

// Anywhere a Task is appropriate — typically a root view's .task modifier.
.task { await store.loadDefaults() }
```

`loadDefaults()` runs concurrently and is safe to call repeatedly. The library doesn't persist `defaults` for you — that's a consumer concern. The usual pattern is to store `[entry.id]` in UserDefaults / SwiftData and re-resolve against your catalog at startup.

## Adding a new kind

CoreML embeddings, Stable Diffusion, anything else:

```swift
// 1. Define the kind.
extension ModelKind {
    static let embedding = ModelKind(id: "embedding", label: "Embedding")
}

// 2. Define the loaded-model wrapper.
final class EmbeddingModel: LoadedModel {
    let kind = ModelKind.embedding
    let repoId: String
    let pipeline: SomeEmbeddingPipeline
    init(repoId: String, pipeline: SomeEmbeddingPipeline) {
        self.repoId = repoId; self.pipeline = pipeline
    }
}

// 3. Define the loader.
struct CoreMLEmbeddingLoader: ModelKindLoader {
    let kind = ModelKind.embedding
    func isDownloaded(repoId: String) -> Bool { /* … */ }
    func startDownload(repoId: String, progressHandler: ...) async throws { /* … */ }
    func load(repoId: String, progressHandler: ...) async throws -> any LoadedModel { /* … */ }
    func delete(repoId: String) { /* … */ }
}

// 4. Register at launch.
registry.register(CoreMLEmbeddingLoader())
```

`ModelStore`, your catalog, and your UI need no changes — they all go through the registry.

## Storage layout

```
Application Support/ModelKit/models/
└── models/                                      ← HuggingFace-style cache
    ├── mlx-community/Llama-3.2-3B-Instruct-4bit/
    │   ├── snapshots/<commit>/...
    │   └── refs/main
    └── argmaxinc/whisperkit-coreml/
        └── openai_whisper-base.en/
            └── ...
```

Layout matches the Python HF cache, so a system Python install can share files.

## Threading

`ModelStore` and `ModelKindRegistry` are `@MainActor`. Loader conformances are `Sendable` and may run anywhere; their `progressHandler` callbacks are `@Sendable (Double) -> Void` — hop to the actor you need before touching UI state.

## Status

- iOS 18+, macOS 15+
- Swift 6.2
- Built against `mlx-swift-lm` 3.31.x, `swift-transformers` 1.3+, `swift-huggingface` 0.9.x, `WhisperKit` `main`

## License

TBD.
