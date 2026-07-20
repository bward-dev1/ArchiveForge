import Foundation

/// Overall progress across an entire batch — distinct from `ArchiveProgress`,
/// which is scoped to whichever single archive is currently being processed.
public struct BatchProgress: Sendable {
    public let currentArchiveIndex: Int
    public let archiveCount: Int
    public let currentArchiveName: String
    public let currentArchiveProgress: ArchiveProgress
    public let overallFractionComplete: Double
}

public typealias BatchProgressHandler = @Sendable (BatchProgress) -> Void

/// Result of a single archive within a batch — success or failure, never
/// thrown: one bad archive in a folder of fifty must never abort the other
/// forty-nine.
public struct BatchItemResult: Sendable {
    public let archive: URL
    public let outcome: Result<[URL], Error>
}

public typealias CheckpointHandler = @Sendable (_ completedCount: Int) -> Void

/// Processes a list of archives one after another (not concurrently — the
/// point is a stable, resumable, single-lane job the UI can show real
/// progress for, not a thread-pool racing several extractions at once).
///
/// `startingAt` plus `onItemComplete` are exactly what background-safe
/// resumption needs: `onItemComplete` fires right after each archive
/// finishes (success OR failure — a failed item still counts as "handled,
/// don't retry it"), which is the caller's cue to persist a `JobCheckpoint`
/// with the new `completedCount`. If the app is killed mid-batch, relaunch
/// calls `run` again with `startingAt: checkpoint.completedCount` and only
/// the untouched tail re-runs — never the whole batch from item 0.
public enum BatchDecompressor {
    public static func run(
        archives: [URL],
        destinationDirectory: URL,
        startingAt startIndex: Int = 0,
        progress: BatchProgressHandler? = nil,
        onItemComplete: CheckpointHandler? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) -> [BatchItemResult] {
        var results: [BatchItemResult] = []
        let total = archives.count

        for index in startIndex..<total {
            // Checked between items, not mid-item — the same granularity
            // checkpointing already uses. Cancelling just stops advancing;
            // whatever checkpoint `onItemComplete` last saved (from a
            // previous item) is exactly what a later "Resume" picks up from,
            // no separate cancellation-recovery path needed.
            if shouldCancel?() == true { break }
            let archive = archives[index]
            let itemDestination = destinationDirectory.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)

            do {
                let extracted = try ArchiveEngine.decompress(archive: archive, to: itemDestination) { itemProgress in
                    let overall = (Double(index) + itemProgress.fractionComplete) / Double(total)
                    progress?(BatchProgress(
                        currentArchiveIndex: index,
                        archiveCount: total,
                        currentArchiveName: archive.lastPathComponent,
                        currentArchiveProgress: itemProgress,
                        overallFractionComplete: overall
                    ))
                }
                results.append(BatchItemResult(archive: archive, outcome: .success(extracted)))
            } catch {
                results.append(BatchItemResult(archive: archive, outcome: .failure(error)))
                progress?(BatchProgress(
                    currentArchiveIndex: index,
                    archiveCount: total,
                    currentArchiveName: archive.lastPathComponent,
                    currentArchiveProgress: ArchiveProgress(itemName: archive.lastPathComponent, fractionComplete: 1, bytesProcessed: 0, totalBytes: 0),
                    overallFractionComplete: Double(index + 1) / Double(total)
                ))
            }
            // Fires after every item regardless of outcome — a checkpoint's
            // job is "don't redo work," not "only checkpoint successes."
            onItemComplete?(index + 1)
        }
        return results
    }
}
