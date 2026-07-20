import Foundation

/// Reads/writes `JobCheckpoint`s as JSON files in a directory the caller
/// provides — pure Foundation, no UIKit/AppKit, so it's testable here and
/// usable from any platform target unchanged. The app layer points this at
/// `FileManager.default.urls(for: .applicationSupportDirectory, ...)`, but
/// this type itself doesn't need to know that.
public struct CheckpointStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).checkpoint.json")
    }

    public func save(_ checkpoint: JobCheckpoint) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: fileURL(for: checkpoint.id), options: .atomic)
    }

    public func delete(_ checkpoint: JobCheckpoint) {
        try? FileManager.default.removeItem(at: fileURL(for: checkpoint.id))
    }

    /// Every incomplete checkpoint on disk, newest first — what the UI offers
    /// as "resume this" on launch. Complete ones are deleted at save time by
    /// the caller, not filtered here, but a defensive check costs nothing.
    public func loadResumable() -> [JobCheckpoint] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        let checkpoints: [JobCheckpoint] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(JobCheckpoint.self, from: data)
            }
            .filter { !$0.isComplete }
        return checkpoints.sorted { $0.createdAt > $1.createdAt }
    }
}
