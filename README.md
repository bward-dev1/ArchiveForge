# ArchiveForge 🗜️

A universal compress/decompress app for iOS & macOS — sleek UI, sequential
batch jobs, and (coming next) a background-safe job architecture plus an
anti-boredom layer for long waits.

> Status: **milestones 1 & 2 done.** Core archive engine (compress/decompress,
> universal format support, sequential batch processing with progress) and
> background-safe resumable jobs (checkpointing + iOS background-time
> extension) are real, working, and verified — see "Verifying the core
> engine" below. The SwiftUI app scaffold (`Sources/ArchiveForgeApp`) is
> reviewed but **not compiler-verified** — it isn't part of any `swift build`
> target (same split as WizardiOS: only the Xcode project generated via
> `xcodegen` compiles it), and no full Xcode is available in this
> environment yet. Treat it as "should be right, not yet proven" until it's
> actually built once.

## Why built this way

Same split as WizardiOS: a pure-Swift `ArchiveForgeKit` package (engine,
batch/job logic — no platform frameworks) that any frontend can drive, plus a
SwiftUI app target generated via XcodeGen. The engine is fully testable and
buildable with just Command Line Tools; the app needs full Xcode.

## Architecture

```
Sources/
  ArchiveForgeKit/          pure-Swift, no system deps — builds & tests without Xcode
    ArchiveFormat.swift        format enum + magic-byte detection
    ArchiveEngine.swift        compress/decompress core (zip/tar/gzip/bzip2/xz/7z)
    ZipWriter.swift            hand-rolled zip writer (SWCompression reads zip but can't write it)
    BatchDecompressor.swift    sequential batch decompression, per-item + overall progress
    BatchCompressor.swift      compress-side mirror of BatchDecompressor
    JobCheckpoint.swift        Codable job state: mode, items, destination, completedCount
    CheckpointStore.swift      saves/loads checkpoints as JSON on disk
    ResumableJobRunner.swift   the actual entry point — starts OR resumes a batch, checkpointing after every item
  ArchiveForgeApp/          SwiftUI frontend (built via the Xcode project, not `swift build`)
    ArchiveForgeApp.swift      app entry
    ContentView.swift          drop zone, format picker, queue list, progress, resume banner
    JobQueueViewModel.swift    @Observable job runner — wires ResumableJobRunner + iOS background-time extension
  SmokeTest/                plain-assertion stopgap for XCTest/Swift Testing (see below)
Tests/
  ArchiveForgeKitTests/      the real test suite — needs full Xcode to run (see below)
```

## Background-safe resumable jobs (milestone 2)

Two mechanisms, together — this is the actual fix for "gets backgrounded and
I have to start over":

1. **Checkpointing.** After every single item in a batch, `ResumableJobRunner`
   writes a `JobCheckpoint` (mode, item list, destination, how many are
   done) to disk as JSON. If the app is killed at any point — background
   suspension, force-quit, crash — at most the one in-flight item is lost,
   never the whole batch. On next launch, `JobQueueViewModel` checks for a
   leftover checkpoint and the UI offers a one-tap "Resume" that picks up
   exactly where it left off (verified: the already-completed items' output
   is never re-touched). A fully finished checkpoint deletes itself instead
   of lingering.
2. **iOS background execution time.** `JobQueueViewModel` requests extra run
   time from the OS the moment a job starts (`UIApplication.beginBackgroundTask`),
   so an ordinary quick app-switch is far more likely to let the job actually
   finish (or at least reach another checkpoint boundary) before the OS
   suspends it, rather than pausing almost immediately. This is the "get more
   done before it matters" half; checkpointing above is the real guarantee
   either way.

macOS doesn't need the background-task-extension piece — apps there aren't
suspended just for not being frontmost — but gets the same checkpointing, so
a crash or force-quit is equally recoverable on that platform too.

## Format support

| Format | Read | Write | Notes |
|---|---|---|---|
| zip | ✅ | ✅ | Reads via SWCompression; writes via a small hand-rolled writer (deflate + local/central-directory records) since SWCompression's zip support is read-only |
| tar | ✅ | ✅ | |
| gzip | ✅ | ✅ | Multi-file compress tars first, same convention as `tar czf` |
| bzip2 | ✅ | ❌ | Decompress-only in SWCompression |
| xz | ✅ | ❌ | Decompress-only in SWCompression |
| 7z | ✅ | ❌ | Decompress-only in SWCompression |

Format detection is magic-byte first, file extension second — a renamed file
still opens correctly.

## Verifying the core engine (no Xcode needed)

```bash
swift build              # builds ArchiveForgeKit
swift run SmokeTest      # runs a battery of round-trip + batch-progress checks
```

`swift test` won't run here — Command Line Tools alone bundles neither
XCTest nor Swift Testing (both are Xcode-only). `Tests/ArchiveForgeKitTests`
is written and ready; it's the suite to trust once Xcode is installed.
`SmokeTest` covers the same ground with plain assertions in the meantime.

## Building the app

```bash
brew install xcodegen && xcodegen generate
open ArchiveForge.xcodeproj
```

Two targets are generated: `ArchiveForge-iOS` and `ArchiveForge-macOS`, both
depending on the same `ArchiveForgeKit` package. Requires full Xcode (not
just Command Line Tools).

## Roadmap

1. ~~Core archive engine + basic UI~~ ✅
2. ~~Background-safe resumable jobs~~ ✅
3. **Anti-boredom layer** — mini-games/trivia/fun-facts shown during long
   jobs, driven by the same progress stream `JobQueueViewModel` already
   exposes
4. **GBA/NDS emulator core integration** — load-your-own-ROM support, same
   model as WizardiOS (the app never ships or embeds any game data itself)
