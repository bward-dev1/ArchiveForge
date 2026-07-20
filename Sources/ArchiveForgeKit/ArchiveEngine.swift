import Foundation
import SWCompression

/// Progress for one step of a (possibly multi-file, possibly multi-archive)
/// job. `fractionComplete` is per-item, not per-job — `BatchDecompressor`
/// composes several of these into overall progress.
public struct ArchiveProgress: Sendable {
    public let itemName: String
    public let fractionComplete: Double
    public let bytesProcessed: Int
    public let totalBytes: Int
}

public typealias ProgressHandler = @Sendable (ArchiveProgress) -> Void

/// Core compress/decompress engine. Pure Swift, no platform frameworks — the
/// same code runs on the macOS and iOS app targets, and is fully unit-testable
/// without Xcode.
public enum ArchiveEngine {
    // MARK: - Decompress

    /// Extracts `archive` into `destinationDirectory`, returning the URLs of
    /// every file written. Handles both true containers (zip/tar/7z, which
    /// hold many files) and bare single-stream compressors (gzip/bzip2/xz,
    /// which decompress to exactly one file — a `.tar.gz` is unwrapped in two
    /// steps: gzip first, then the resulting tar).
    public static func decompress(
        archive url: URL,
        to destinationDirectory: URL,
        format: ArchiveFormat? = nil,
        progress: ProgressHandler? = nil
    ) throws -> [URL] {
        let resolvedFormat = try format ?? ArchiveFormat.detect(contentsOf: url)
        let data = try Data(contentsOf: url)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        switch resolvedFormat {
        case .zip:
            let entries = try ZipContainer.open(container: data)
            return try writeContainerEntries(entries.map { (path: $0.info.name, data: $0.data ?? Data(), isDirectory: $0.info.type == .directory) },
                                              to: destinationDirectory, jobName: url.lastPathComponent, progress: progress)

        case .sevenZip:
            let entries = try SevenZipContainer.open(container: data)
            return try writeContainerEntries(entries.map { (path: $0.info.name, data: $0.data ?? Data(), isDirectory: $0.info.type == .directory) },
                                              to: destinationDirectory, jobName: url.lastPathComponent, progress: progress)

        case .tar:
            let entries = try TarContainer.open(container: data)
            return try writeContainerEntries(entries.map { (path: $0.info.name, data: $0.data ?? Data(), isDirectory: $0.info.type == .directory) },
                                              to: destinationDirectory, jobName: url.lastPathComponent, progress: progress)

        case .gzip:
            let decompressed = try GzipArchive.unarchive(archive: data)
            return try writeSingleStream(decompressed, sourceURL: url, stripExtension: "gz",
                                          to: destinationDirectory, progress: progress)

        case .bzip2:
            let decompressed = try BZip2.decompress(data: data)
            return try writeSingleStream(decompressed, sourceURL: url, stripExtension: "bz2",
                                          to: destinationDirectory, progress: progress)

        case .xz:
            let decompressed = try XZArchive.unarchive(archive: data)
            return try writeSingleStream(decompressed, sourceURL: url, stripExtension: "xz",
                                          to: destinationDirectory, progress: progress)
        }
    }

    // MARK: - Compress

    /// Compresses `files` into a single archive at `destination`. Multiple
    /// files into a single-stream format (gzip/bzip2/xz) are tarred first —
    /// same convention as the command-line tools (`tar czf`), since those
    /// formats have no concept of "more than one file" on their own.
    public static func compress(
        files: [URL],
        to destination: URL,
        format: ArchiveFormat,
        progress: ProgressHandler? = nil
    ) throws {
        guard !files.isEmpty else { throw ArchiveError.emptyInput }
        guard format.canWrite else { throw ArchiveError.unwritableFormat(format) }

        switch format {
        case .zip:
            // Streams straight to `destination` — each file is read,
            // compressed, and written before the next one is even opened, so
            // peak memory is bounded by the single largest file, not the sum
            // of every file in the batch (unlike the .tar/.gzip branches
            // below, which still have to materialize everything at once —
            // that's an inherent SWCompression API constraint on those
            // formats' writers, not something fixable here; see ZipWriter's
            // own doc comment). Progress is reported by ZipWriter itself,
            // after each file's real work completes, not precomputed here.
            let zipEntries = files.map { ZipWriter.FileEntry(name: $0.lastPathComponent, url: $0) }
            try ZipWriter.write(entries: zipEntries, to: destination, progress: progress)

        case .tar:
            let entries = try makeTarEntries(from: files, progress: progress)
            let data = TarContainer.create(from: entries)
            try data.write(to: destination)

        case .gzip, .bzip2, .xz:
            let payload: Data
            if files.count == 1 {
                payload = try Data(contentsOf: files[0])
            } else {
                let entries = try makeTarEntries(from: files, progress: progress)
                payload = TarContainer.create(from: entries)
            }
            let compressed: Data
            switch format {
            case .gzip: compressed = try GzipArchive.archive(data: payload)
            case .bzip2: throw ArchiveError.unwritableFormat(.bzip2) // decompress-only in SWCompression
            case .xz: throw ArchiveError.unwritableFormat(.xz) // decompress-only in SWCompression
            default: fatalError("unreachable")
            }
            try compressed.write(to: destination)

        case .sevenZip:
            throw ArchiveError.unwritableFormat(.sevenZip)
        }
    }

    // MARK: - Helpers

    private static func loadFiles(from files: [URL], progress: ProgressHandler?) throws -> [(name: String, data: Data)] {
        var loaded: [(name: String, data: Data)] = []
        let total = files.count
        for (index, url) in files.enumerated() {
            let data = try Data(contentsOf: url)
            loaded.append((name: url.lastPathComponent, data: data))
            progress?(ArchiveProgress(itemName: url.lastPathComponent,
                                       fractionComplete: Double(index + 1) / Double(total),
                                       bytesProcessed: index + 1, totalBytes: total))
        }
        return loaded
    }

    private static func makeTarEntries(from files: [URL], progress: ProgressHandler?) throws -> [TarEntry] {
        try loadFiles(from: files, progress: progress).map { loaded in
            TarEntry(info: TarEntryInfo(name: loaded.name, type: .regular), data: loaded.data)
        }
    }

    private static func writeContainerEntries(
        _ entries: [(path: String, data: Data, isDirectory: Bool)],
        to destinationDirectory: URL,
        jobName: String,
        progress: ProgressHandler?
    ) throws -> [URL] {
        var written: [URL] = []
        let total = entries.count
        for (index, entry) in entries.enumerated() {
            let outURL = destinationDirectory.appendingPathComponent(entry.path)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try entry.data.write(to: outURL)
                written.append(outURL)
            }
            progress?(ArchiveProgress(itemName: entry.path,
                                       fractionComplete: Double(index + 1) / Double(total),
                                       bytesProcessed: index + 1, totalBytes: total))
        }
        return written
    }

    private static func writeSingleStream(
        _ data: Data,
        sourceURL: URL,
        stripExtension: String,
        to destinationDirectory: URL,
        progress: ProgressHandler?
    ) throws -> [URL] {
        var name = sourceURL.lastPathComponent
        if name.hasSuffix(".\(stripExtension)") {
            name = String(name.dropLast(stripExtension.count + 1))
        }
        let outURL = destinationDirectory.appendingPathComponent(name)
        try data.write(to: outURL)
        progress?(ArchiveProgress(itemName: name, fractionComplete: 1, bytesProcessed: data.count, totalBytes: data.count))
        return [outURL]
    }
}
