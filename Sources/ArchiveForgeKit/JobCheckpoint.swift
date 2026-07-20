import Foundation

/// Everything needed to resume a batch job exactly where it left off,
/// instead of restarting from item 0 — the whole point of this milestone.
/// Saved to disk after every completed item, so even a hard app kill
/// (not just a background suspension) loses at most one in-flight item.
public struct JobCheckpoint: Codable, Sendable, Identifiable {
    public let id: UUID
    public let mode: JobModeDescriptor
    public let format: ArchiveFormat
    public let itemURLs: [URL]
    public var completedCount: Int
    public let destinationDirectory: URL
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        mode: JobModeDescriptor,
        format: ArchiveFormat,
        itemURLs: [URL],
        completedCount: Int = 0,
        destinationDirectory: URL,
        createdAt: Date
    ) {
        self.id = id
        self.mode = mode
        self.format = format
        self.itemURLs = itemURLs
        self.completedCount = completedCount
        self.destinationDirectory = destinationDirectory
        self.createdAt = createdAt
    }

    /// True once every item has been processed — a finished checkpoint is
    /// safe to delete rather than offered as "resume this."
    public var isComplete: Bool {
        completedCount >= itemURLs.count
    }
}

/// Mirrors the app layer's `JobMode` without ArchiveForgeKit depending on it
/// (the Kit has no UI dependency at all) — compress vs. decompress is the
/// only distinction that actually changes how `completedCount` resumes.
public enum JobModeDescriptor: String, Codable, Sendable {
    case compress
    case decompress
}
