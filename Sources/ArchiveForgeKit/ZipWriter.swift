import Foundation
import SWCompression

/// SWCompression can *read* zip (`ZipContainer.open`) but has no writer at
/// all — so writing one is the only way to make zip a round-trippable format
/// here. The format itself is simple enough to hand-roll correctly: local
/// file headers, deflated entry data, then a central directory and one
/// end-of-central-directory record. No zip64, no encryption, no split
/// archives — just what a personal archiver actually needs.
///
/// Writes to `destination` incrementally via `FileHandle` rather than
/// building one in-memory `Data` blob and writing it all at once — a real
/// fix, not a cosmetic one: compressing N files used to mean holding every
/// one of their full contents in memory simultaneously before writing
/// anything, so a batch of large files could exhaust memory well before
/// producing any output. Peak memory here is bounded by the single largest
/// file being compressed at any given moment, not the sum of all of them.
/// (`Deflate.compress` itself still takes one whole file's `Data` at a time
/// — that per-file bound is an inherent SWCompression API constraint, not
/// something fixable without a different deflate implementation.)
enum ZipWriter {
    struct FileEntry {
        let name: String
        let url: URL
    }

    static func write(entries: [FileEntry], to destination: URL, progress: ProgressHandler? = nil) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var centralDirectory = Data()
        var centralDirectoryEntryCount: UInt16 = 0
        let total = entries.count

        for (index, entry) in entries.enumerated() {
            let nameBytes = Array(entry.name.utf8)
            let fileData = try Data(contentsOf: entry.url)
            let compressed = Deflate.compress(data: fileData)
            let crc = crc32(fileData)
            let localHeaderOffset = offset

            var local = Data()
            local.append(littleEndian: UInt32(0x0403_4B50))
            local.append(littleEndian: UInt16(20))       // version needed to extract
            local.append(littleEndian: UInt16(0))        // general purpose flag
            local.append(littleEndian: UInt16(8))        // method 8 = deflate
            local.append(littleEndian: UInt16(0))        // mod time (unset — not worth the DOS-date conversion for a personal tool)
            local.append(littleEndian: UInt16(0))        // mod date
            local.append(littleEndian: crc)
            local.append(littleEndian: UInt32(compressed.count))
            local.append(littleEndian: UInt32(fileData.count))
            local.append(littleEndian: UInt16(nameBytes.count))
            local.append(littleEndian: UInt16(0))        // extra field length
            local.append(contentsOf: nameBytes)
            handle.write(local)
            handle.write(compressed)
            offset += UInt64(local.count + compressed.count)

            // Central directory record (PK\x01\x02) — mirrors the local
            // header plus the offset back to it. Kept in memory across the
            // whole write (it's metadata only, bytes-of-filenames scale, not
            // bytes-of-file-content scale) and flushed to disk once at the end,
            // since every entry's record has to land contiguously there.
            var central = Data()
            central.append(littleEndian: UInt32(0x0201_4B50))
            central.append(littleEndian: UInt16(20))     // version made by
            central.append(littleEndian: UInt16(20))     // version needed to extract
            central.append(littleEndian: UInt16(0))
            central.append(littleEndian: UInt16(8))
            central.append(littleEndian: UInt16(0))
            central.append(littleEndian: UInt16(0))
            central.append(littleEndian: crc)
            central.append(littleEndian: UInt32(compressed.count))
            central.append(littleEndian: UInt32(fileData.count))
            central.append(littleEndian: UInt16(nameBytes.count))
            central.append(littleEndian: UInt16(0))      // extra field length
            central.append(littleEndian: UInt16(0))      // comment length
            central.append(littleEndian: UInt16(0))      // disk number start
            central.append(littleEndian: UInt16(0))      // internal attributes
            central.append(littleEndian: UInt32(0))      // external attributes
            central.append(littleEndian: UInt32(localHeaderOffset))
            central.append(contentsOf: nameBytes)
            centralDirectory.append(central)
            centralDirectoryEntryCount += 1
            // `fileData`/`compressed` go out of scope at the end of this
            // iteration — nothing about this file's content is retained
            // once its bytes are written and its central-directory record
            // (which holds no file content, just fixed-size metadata plus
            // the filename) is appended.

            // Reported AFTER this file's actual read+compress+write, not
            // pre-computed for the whole batch upfront — progress has to
            // track real completed work, or it reports "100%" the instant
            // the loop starts rather than when it actually finishes.
            progress?(ArchiveProgress(itemName: entry.name,
                                       fractionComplete: Double(index + 1) / Double(total),
                                       bytesProcessed: index + 1, totalBytes: total))
        }

        let centralDirectoryOffset = offset
        handle.write(centralDirectory)

        var eocd = Data()
        eocd.append(littleEndian: UInt32(0x0605_4B50))
        eocd.append(littleEndian: UInt16(0))  // disk number
        eocd.append(littleEndian: UInt16(0))  // disk with central directory
        eocd.append(littleEndian: centralDirectoryEntryCount)
        eocd.append(littleEndian: centralDirectoryEntryCount)
        eocd.append(littleEndian: UInt32(centralDirectory.count))
        eocd.append(littleEndian: UInt32(centralDirectoryOffset))
        eocd.append(littleEndian: UInt16(0))  // comment length
        handle.write(eocd)
    }

    /// Standard IEEE 802.3 CRC-32 (the polynomial zip itself requires) —
    /// SWCompression computes this internally but doesn't expose it publicly,
    /// so it needs its own table-based implementation here.
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = (crc ^ UInt32(byte)) & 0xFF
            crc = (crc >> 8) ^ crc32Table[Int(index)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
}
