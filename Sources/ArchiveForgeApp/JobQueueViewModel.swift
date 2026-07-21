import ArchiveForgeKit
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// One file the user has queued, plus its own real-time status — the model
/// backing the sequential batch list in the UI. `@MainActor`-isolated (not
/// just conventionally-only-touched-there): every real mutation of `status`/
/// `fractionComplete` already happens inside `Task { @MainActor in ... }`
/// blocks in JobQueueViewModel, so this makes that invariant something the
/// compiler enforces, and — the reason it matters here specifically —
/// MainActor isolation is what lets a reference to this class be captured
/// inside a `@Sendable` closure at all (opaque access only, no touching its
/// properties without hopping back to MainActor first, exactly what the
/// code already does).
@MainActor
@Observable
final class QueuedItem: Identifiable {
    let id = UUID()
    let url: URL
    var status: Status = .pending
    var fractionComplete: Double = 0

    enum Status: Equatable {
        case pending
        case running
        case done
        case failed(String)
    }

    init(url: URL) {
        self.url = url
    }
}

/// A real lock-protected flag, not `nonisolated(unsafe)` — unlike the
/// checkpoint-handler closures elsewhere in this codebase (which really are
/// only ever touched serially, single-threaded), this one is genuinely
/// touched from two different threads at once: the main actor sets it when
/// the user taps Cancel, while `BatchDecompressor`/`BatchCompressor`'s loop
/// polls it from inside `Task.detached`'s background thread. That's an
/// actual race without a real lock.
final class CancellationFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()

    func requestCancel() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        flag = false
    }

    func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}

public enum JobMode: String, CaseIterable, Identifiable {
    case compress = "Compress"
    case decompress = "Decompress"
    public var id: String { rawValue }

    var descriptor: JobModeDescriptor {
        switch self {
        case .compress: return .compress
        case .decompress: return .decompress
        }
    }
}

/// Drives the queue shown in ContentView. Two things make a job
/// background-safe, together:
///
/// 1. **Checkpointing** (`ResumableJobRunner`/`CheckpointStore`, milestone 2's
///    actual fix): progress is persisted to disk after every item, so even a
///    hard kill mid-batch loses at most one in-flight item — relaunching
///    finds the checkpoint and resumes the untouched tail instead of
///    starting over.
/// 2. **Background execution time** (iOS only): requesting extra run time
///    from the OS when the app is about to suspend, so a batch actually gets
///    more real wall-clock time to finish *before* checkpointing even
///    becomes necessary. Belt and suspenders — either one alone still beats
///    "restart from item 0."
@Observable
@MainActor
final class JobQueueViewModel {
    var items: [QueuedItem] = []
    var mode: JobMode = .decompress
    var format: ArchiveFormat = .zip
    var isRunning = false
    var overallFraction: Double = 0
    var destinationDirectory: URL = FileManager.default.temporaryDirectory
    var lastErrorMessage: String?
    var resumableCheckpoint: JobCheckpoint?

    private let checkpointStore: CheckpointStore
    private let cancelFlag = CancellationFlag()
    let romLibrary: ROMLibrary
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        checkpointStore = CheckpointStore(directory: appSupport.appendingPathComponent("ArchiveForge/Checkpoints"))
        romLibrary = ROMLibrary(storageDirectory: appSupport.appendingPathComponent("ArchiveForge/ROMLibrary"))
        checkForResumableJob()
    }

    /// Imports any GBA/NDS files among the newly-added items straight into
    /// the persistent ROM library — the "make the ROMs I load persistent"
    /// half of this milestone. Everything else about `addFiles` (queuing for
    /// compress/decompress) is unaffected; a file can be both queued for a
    /// job and added to the library at once.
    func importROMsIfApplicable(from urls: [URL]) {
        for url in urls {
            _ = try? romLibrary.importROM(from: url)
        }
    }

    /// Call on launch/foreground — surfaces any job a previous run didn't
    /// finish (background kill, crash, force-quit) so the UI can offer to
    /// pick it back up instead of the user rebuilding the whole queue.
    func checkForResumableJob() {
        resumableCheckpoint = checkpointStore.loadResumable().first
    }

    func resumeInterruptedJob() {
        guard let checkpoint = resumableCheckpoint else { return }
        isRunning = true
        overallFraction = Double(checkpoint.completedCount) / Double(max(checkpoint.itemURLs.count, 1))
        lastErrorMessage = nil
        resumableCheckpoint = nil
        cancelFlag.reset()

        let store = checkpointStore
        let flag = cancelFlag
        beginBackgroundTaskIfNeeded()

        // AsyncStream, not a captured `self` inside Task.detached: Swift 6's
        // "sending" checker flags a `[weak self]` capture on a .detached
        // closure as a data-race risk even when the actual touch of `self`
        // is buried inside a nested `MainActor.run` — real, CI-caught error
        // (see the commit this comment landed in). The fix isn't a smaller
        // capture list, it's not capturing `self` into the detached closure
        // at all: the producer below is 100% self-free (only genuinely
        // Sendable value captures), and two separate, naturally-MainActor
        // Tasks (declared directly in this @MainActor method, so `self`
        // needs no capture-list gymnastics at all) consume the stream and
        // the final awaited result.
        let (progressStream, progressContinuation) = AsyncStream<BatchProgress>.makeStream()

        let jobTask = Task.detached {
            ResumableJobRunner.resume(checkpoint, store: store) { progress in
                progressContinuation.yield(progress)
            } shouldCancel: {
                flag.isCancelled()
            }
        }

        Task { @MainActor [weak self] in
            for await progress in progressStream {
                self?.overallFraction = progress.overallFractionComplete
            }
        }

        Task { @MainActor [weak self] in
            let (resultCheckpoint, results) = await jobTask.value
            progressContinuation.finish()
            guard let self else { return }
            self.reportFailures(in: results)
            self.isRunning = false
            self.endBackgroundTaskIfNeeded()
            // Cancelled mid-resume leaves a still-incomplete checkpoint —
            // same as a fresh cancellation, surface it as resumable again
            // rather than silently dropping it.
            if !resultCheckpoint.isComplete {
                self.resumableCheckpoint = resultCheckpoint
            }
        }
    }

    /// Stops the current job after whichever item is in flight finishes —
    /// not mid-item, same granularity as a background interruption. Reuses
    /// the exact same checkpoint a background kill would leave: what's done
    /// stays done, and "Resume" picks up the rest later, or "Discard" drops
    /// it entirely.
    func cancel() {
        guard isRunning else { return }
        cancelFlag.requestCancel()
    }

    func discardResumableJob() {
        guard let checkpoint = resumableCheckpoint else { return }
        checkpointStore.delete(checkpoint)
        resumableCheckpoint = nil
    }

    func addFiles(_ urls: [URL]) {
        items.append(contentsOf: urls.map(QueuedItem.init))
    }

    func removeItem(_ item: QueuedItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        items.removeAll { if case .done = $0.status { return true }; return false }
    }

    func start() {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true
        overallFraction = 0
        lastErrorMessage = nil
        cancelFlag.reset()

        let mode = self.mode
        let format = self.format
        let destination = self.destinationDirectory
        let itemsSnapshot = items
        let urls = itemsSnapshot.map(\.url)
        let byURL = Dictionary(uniqueKeysWithValues: itemsSnapshot.map { ($0.url, $0) })
        let store = checkpointStore
        let flag = cancelFlag

        beginBackgroundTaskIfNeeded()

        // Same AsyncStream restructuring as resumeInterruptedJob() — see
        // that function's comment for why: a `[weak self]` capture on a
        // Task.detached closure is a real, CI-caught Swift 6 "sending self"
        // error even when the actual self-touch is buried inside a nested
        // MainActor block. `jobTask` below is 100% self-free (only Sendable
        // value captures); `byURL` (keyed on QueuedItem, not Sendable) is
        // used only in the two naturally-MainActor consumer Tasks, never
        // inside the detached producer.
        let (progressStream, progressContinuation) = AsyncStream<BatchProgress>.makeStream()

        let jobTask = Task.detached {
            let onProgress: @Sendable (BatchProgress) -> Void = { progressContinuation.yield($0) }
            let results: [BatchItemResult]
            let resultCheckpoint: JobCheckpoint
            switch mode {
            case .decompress:
                (resultCheckpoint, results) = ResumableJobRunner.startDecompress(
                    archives: urls, destinationDirectory: destination, store: store, progress: onProgress
                ) { flag.isCancelled() }
            case .compress:
                (resultCheckpoint, results) = ResumableJobRunner.startCompress(
                    files: urls, destinationDirectory: destination, format: format, store: store, progress: onProgress
                ) { flag.isCancelled() }
            }
            return (resultCheckpoint, results)
        }

        Task { @MainActor [weak self] in
            for await progress in progressStream {
                guard progress.currentArchiveIndex < urls.count,
                      let item = byURL[urls[progress.currentArchiveIndex]] else { continue }
                item.status = .running
                item.fractionComplete = progress.currentArchiveProgress.fractionComplete
                self?.overallFraction = progress.overallFractionComplete
            }
        }

        Task { @MainActor [weak self] in
            let (resultCheckpoint, results) = await jobTask.value
            progressContinuation.finish()
            guard let self else { return }
            for result in results {
                guard let item = byURL[result.archive] else { continue }
                switch result.outcome {
                case .success:
                    item.status = .done
                    item.fractionComplete = 1
                case .failure(let error):
                    item.status = .failed(error.localizedDescription)
                    self.lastErrorMessage = error.localizedDescription
                }
            }
            self.isRunning = false
            self.endBackgroundTaskIfNeeded()
            if !resultCheckpoint.isComplete {
                self.resumableCheckpoint = resultCheckpoint
            }
        }
    }

    private func reportFailures(in results: [BatchItemResult]) {
        for result in results {
            if case .failure(let error) = result.outcome {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Background execution time (iOS)

    /// Asks iOS for extra run time before the OS suspends the app — without
    /// this, backgrounding mid-job (switching apps, locking the phone) can
    /// pause execution almost immediately. This doesn't guarantee the job
    /// finishes before the extension runs out, which is exactly why
    /// checkpointing above exists as the actual guarantee — this just makes
    /// reaching a checkpoint boundary, or finishing outright, much more
    /// likely on an ordinary quick app-switch.
    private func beginBackgroundTaskIfNeeded() {
        #if os(iOS)
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ArchiveForge.batchJob") { [weak self] in
            // Expiration handler: time ran out before the job reached a
            // checkpoint boundary. End the task promptly (the OS terminates
            // the app shortly after if this doesn't return quickly) — the
            // on-disk checkpoint from the last completed item is still
            // there, so relaunch still resumes correctly.
            self?.endBackgroundTaskIfNeeded()
        }
        #endif
    }

    private func endBackgroundTaskIfNeeded() {
        #if os(iOS)
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        #endif
    }
}
