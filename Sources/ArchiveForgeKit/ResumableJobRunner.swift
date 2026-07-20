import Foundation

/// Ties `CheckpointStore` together with `BatchDecompressor`/`BatchCompressor`:
/// this is the one entry point the app layer calls, whether starting a
/// brand-new batch or resuming one found on disk after a background kill.
/// The app never has to remember to wire checkpointing correctly itself —
/// it's inseparable from running the job at all here.
public enum ResumableJobRunner {
    public static func startDecompress(
        archives: [URL],
        destinationDirectory: URL,
        store: CheckpointStore,
        progress: BatchProgressHandler? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) -> (checkpoint: JobCheckpoint, results: [BatchItemResult]) {
        let checkpoint = JobCheckpoint(
            mode: .decompress,
            format: .zip, // decompress auto-detects per-file; format is only meaningful for a compress-mode checkpoint
            itemURLs: archives,
            destinationDirectory: destinationDirectory,
            createdAt: Date()
        )
        return run(checkpoint, store: store, progress: progress, shouldCancel: shouldCancel)
    }

    public static func startCompress(
        files: [URL],
        destinationDirectory: URL,
        format: ArchiveFormat,
        store: CheckpointStore,
        progress: BatchProgressHandler? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) -> (checkpoint: JobCheckpoint, results: [BatchItemResult]) {
        let checkpoint = JobCheckpoint(
            mode: .compress,
            format: format,
            itemURLs: files,
            destinationDirectory: destinationDirectory,
            createdAt: Date()
        )
        return run(checkpoint, store: store, progress: progress, shouldCancel: shouldCancel)
    }

    /// Resumes a previously-saved checkpoint of either mode — the untouched
    /// tail runs, the already-completed prefix does not, no matter how the
    /// app was interrupted (background suspension, force-quit, crash) OR
    /// deliberately cancelled — cancellation just leaves the same kind of
    /// checkpoint an interruption would, resumable the same way.
    public static func resume(
        _ checkpoint: JobCheckpoint,
        store: CheckpointStore,
        progress: BatchProgressHandler? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) -> (checkpoint: JobCheckpoint, results: [BatchItemResult]) {
        run(checkpoint, store: store, progress: progress, startingAt: checkpoint.completedCount, shouldCancel: shouldCancel)
    }

    private static func run(
        _ checkpoint: JobCheckpoint,
        store: CheckpointStore,
        progress: BatchProgressHandler?,
        startingAt startIndex: Int = 0,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) -> (checkpoint: JobCheckpoint, results: [BatchItemResult]) {
        // Both BatchDecompressor.run and BatchCompressor.run are plain
        // synchronous for-loops — onItemComplete is never actually invoked
        // concurrently, even though its type is @Sendable for the sake of
        // callers elsewhere (JobQueueViewModel drives this from inside a
        // Task.detached). `nonisolated(unsafe)` reflects that real, verified
        // serial execution instead of fighting Swift 6's static checker with
        // an actor for no actual benefit here.
        nonisolated(unsafe) var checkpoint = checkpoint
        try? store.save(checkpoint)

        let onItemComplete: CheckpointHandler = { completedCount in
            checkpoint.completedCount = completedCount
            try? store.save(checkpoint)
        }

        let results: [BatchItemResult]
        switch checkpoint.mode {
        case .decompress:
            results = BatchDecompressor.run(
                archives: checkpoint.itemURLs,
                destinationDirectory: checkpoint.destinationDirectory,
                startingAt: startIndex,
                progress: progress,
                onItemComplete: onItemComplete,
                shouldCancel: shouldCancel
            )
        case .compress:
            results = BatchCompressor.run(
                files: checkpoint.itemURLs,
                destinationDirectory: checkpoint.destinationDirectory,
                format: checkpoint.format,
                startingAt: startIndex,
                progress: progress,
                onItemComplete: onItemComplete,
                shouldCancel: shouldCancel
            )
        }

        if checkpoint.isComplete {
            store.delete(checkpoint)
        } else {
            try? store.save(checkpoint)
        }
        return (checkpoint, results)
    }
}
