import Foundation

/// Compress-side mirror of `BatchDecompressor` — each item in `files` becomes
/// its own archive at `destinationDirectory`, one after another, with the
/// same `startingAt`/`onItemComplete` shape so `ResumableJobRunner` can drive
/// either direction identically.
public enum BatchCompressor {
    public static func run(
        files: [URL],
        destinationDirectory: URL,
        format: ArchiveFormat,
        startingAt startIndex: Int = 0,
        progress: BatchProgressHandler? = nil,
        onItemComplete: CheckpointHandler? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) -> [BatchItemResult] {
        var results: [BatchItemResult] = []
        let total = files.count

        for index in startIndex..<total {
            if shouldCancel?() == true { break }
            let file = files[index]
            let destination = destinationDirectory
                .appendingPathComponent(file.deletingPathExtension().lastPathComponent + "." + format.fileExtension)

            do {
                try ArchiveEngine.compress(files: [file], to: destination, format: format) { itemProgress in
                    let overall = (Double(index) + itemProgress.fractionComplete) / Double(total)
                    progress?(BatchProgress(
                        currentArchiveIndex: index,
                        archiveCount: total,
                        currentArchiveName: file.lastPathComponent,
                        currentArchiveProgress: itemProgress,
                        overallFractionComplete: overall
                    ))
                }
                results.append(BatchItemResult(archive: file, outcome: .success([destination])))
            } catch {
                results.append(BatchItemResult(archive: file, outcome: .failure(error)))
                progress?(BatchProgress(
                    currentArchiveIndex: index,
                    archiveCount: total,
                    currentArchiveName: file.lastPathComponent,
                    currentArchiveProgress: ArchiveProgress(itemName: file.lastPathComponent, fractionComplete: 1, bytesProcessed: 0, totalBytes: 0),
                    overallFractionComplete: Double(index + 1) / Double(total)
                ))
            }
            onItemComplete?(index + 1)
        }
        return results
    }
}
