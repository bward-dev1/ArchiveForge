import Foundation

/// A container/compression format ArchiveForge can read and/or write.
///
/// Detection is magic-byte first, extension second: a renamed file (a `.zip`
/// that's actually a `.tar`, say) should still open correctly, which a
/// pure-extension check can't guarantee.
public enum ArchiveFormat: String, CaseIterable, Sendable, Codable {
    case zip
    case tar
    case gzip
    case bzip2
    case xz
    case sevenZip = "7z"

    /// SWCompression only writes zip/tar/gzip — bzip2, xz, and 7z are
    /// decompress-only in that library, so those three are read-only here too.
    public var canWrite: Bool {
        switch self {
        case .zip, .tar, .gzip: return true
        case .bzip2, .xz, .sevenZip: return false
        }
    }

    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tar: return "tar"
        case .gzip: return "gz"
        case .bzip2: return "bz2"
        case .xz: return "xz"
        case .sevenZip: return "7z"
        }
    }

    /// Detects format from the file's own leading bytes, falling back to its
    /// extension only when the header is too short or genuinely ambiguous.
    public static func detect(contentsOf url: URL) throws -> ArchiveFormat {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 6) ?? Data()

        if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) || header.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return .zip
        }
        if header.starts(with: [0x1F, 0x8B]) {
            return .gzip
        }
        if header.starts(with: [0x42, 0x5A, 0x68]) { // "BZh"
            return .bzip2
        }
        if header.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return .xz
        }
        if header.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            return .sevenZip
        }
        // TAR's magic ("ustar") sits 257 bytes in, not at the start, and plenty
        // of real-world tarballs predate that field entirely — extension is
        // the only reliable signal left for those.
        if url.pathExtension.lowercased() == "tar" {
            return .tar
        }
        throw ArchiveError.unrecognizedFormat(url.lastPathComponent)
    }
}

public enum ArchiveError: Error, LocalizedError, Sendable {
    case unrecognizedFormat(String)
    case unwritableFormat(ArchiveFormat)
    case emptyInput
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat(let name):
            return "Couldn't recognize \(name) as a supported archive format."
        case .unwritableFormat(let format):
            return "\(format.rawValue) archives can be opened but not created."
        case .emptyInput:
            return "No files were given to compress."
        case .underlying(let message):
            return message
        }
    }
}
