import Foundation

/// A ROM the user has loaded into ArchiveForge themselves — persisted so it
/// survives app relaunch, and so the anti-boredom layer has something real
/// to offer ("play a bit of what's already in your library") instead of
/// only generic minigames. ArchiveForge never supplies, downloads, or ships
/// ROM data of its own — every entry here traces back to a file the user
/// picked via the system file importer.
public struct LoadedROM: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let system: ROMSystem
    /// Path relative to the library's storage directory — never an absolute
    /// path from wherever the user originally picked the file, since that
    /// location (especially a security-scoped temporary URL from an iOS file
    /// picker) isn't guaranteed to still exist or be accessible later.
    public let relativeStoragePath: String
    public let addedAt: Date
    public var lastPlayedAt: Date?

    public init(id: UUID = UUID(), title: String, system: ROMSystem, relativeStoragePath: String, addedAt: Date, lastPlayedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.system = system
        self.relativeStoragePath = relativeStoragePath
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
    }
}

public enum ROMSystem: String, Codable, Sendable, CaseIterable {
    case gba
    case nds

    static func detect(from url: URL) -> ROMSystem? {
        switch url.pathExtension.lowercased() {
        case "gba": return .gba
        case "nds": return .nds
        default: return nil
        }
    }
}

public enum ROMLibraryError: Error, LocalizedError, Sendable {
    case unrecognizedExtension(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedExtension(let ext):
            return "\".\(ext)\" isn't a recognized GBA/NDS ROM extension."
        }
    }
}

/// Persistent library of the user's own loaded ROMs. Pure Foundation, no
/// platform frameworks — the app layer points `storageDirectory` at
/// Application Support, but this type itself doesn't need to know that,
/// same convention as `CheckpointStore`.
public struct ROMLibrary: Sendable {
    public let storageDirectory: URL
    private var indexURL: URL { storageDirectory.appendingPathComponent("index.json") }
    private var romsDirectory: URL { storageDirectory.appendingPathComponent("ROMs") }

    public init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
    }

    /// Copies `url` into the library's own storage and records it — the
    /// copy is what makes this "persistent": the original file (Downloads, a
    /// picker's temp location, wherever) can disappear afterward with no
    /// effect on the library.
    @discardableResult
    public func importROM(from url: URL) throws -> LoadedROM {
        guard let system = ROMSystem.detect(from: url) else {
            throw ROMLibraryError.unrecognizedExtension(url.pathExtension)
        }
        try FileManager.default.createDirectory(at: romsDirectory, withIntermediateDirectories: true)

        let id = UUID()
        let storedFilename = "\(id.uuidString).\(url.pathExtension.lowercased())"
        let destination = romsDirectory.appendingPathComponent(storedFilename)
        let data = try Data(contentsOf: url)
        try data.write(to: destination)

        let title = url.deletingPathExtension().lastPathComponent
        let rom = LoadedROM(id: id, title: title, system: system, relativeStoragePath: "ROMs/\(storedFilename)", addedAt: Date())

        var all = allROMs()
        all.append(rom)
        try save(all)
        return rom
    }

    public func allROMs() -> [LoadedROM] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([LoadedROM].self, from: data)) ?? []
    }

    /// Most-recently-played first, then most-recently-added — what the
    /// anti-boredom carousel offers first, since "the thing you were just
    /// playing" is the likeliest thing you want to jump back into.
    public func recentROMs(limit: Int = 5) -> [LoadedROM] {
        Array(
            allROMs().sorted { lhs, rhs in
                (lhs.lastPlayedAt ?? lhs.addedAt) > (rhs.lastPlayedAt ?? rhs.addedAt)
            }.prefix(limit)
        )
    }

    public func storageURL(for rom: LoadedROM) -> URL {
        storageDirectory.appendingPathComponent(rom.relativeStoragePath)
    }

    public func markPlayed(_ rom: LoadedROM) throws {
        var all = allROMs()
        guard let index = all.firstIndex(where: { $0.id == rom.id }) else { return }
        all[index].lastPlayedAt = Date()
        try save(all)
    }

    public func remove(_ rom: LoadedROM) throws {
        try? FileManager.default.removeItem(at: storageURL(for: rom))
        var all = allROMs()
        all.removeAll { $0.id == rom.id }
        try save(all)
    }

    private func save(_ roms: [LoadedROM]) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(roms)
        try data.write(to: indexURL, options: .atomic)
    }
}
