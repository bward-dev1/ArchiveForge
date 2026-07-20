import Foundation

/// Short, original "did you know" facts shown during long jobs — general
/// knowledge about compression and gaming history, written in this
/// project's own words rather than quoted from anywhere.
public struct FunFactProvider: Sendable {
    private static let facts = [
        "The ZIP format was created in 1989 by Phil Katz for his PKZIP tool — it's older than the World Wide Web.",
        "Deflate, the algorithm most ZIP files use internally, combines two older techniques: LZ77 and Huffman coding.",
        "LZMA (used in .7z and .xz files) generally compresses tighter than Deflate, but takes noticeably longer to do it.",
        "Lossless compression works because most real files have redundancy — repeated patterns a smart algorithm can shorten.",
        "The Game Boy Advance's screen never had a backlight in its original 2001 model — that came two years later with the SP.",
        "The Nintendo DS's second screen was originally pitched internally as a gimmick nobody expected to become a signature feature.",
        "GBA cartridges could hold up to 32 megabytes — tiny by today's standards, but developers still packed entire RPGs into that space.",
        "A CRC32 checksum (the kind ZIP files use to verify integrity) can't guarantee a file is unchanged — just that it's astronomically unlikely to be corrupted in exactly the right way to fool it.",
        "Tar, one of the oldest archive formats still in daily use, gets its name from \"tape archive\" — it was originally designed for writing to magnetic tape.",
        "Emulator authors often reverse-engineer real hardware behavior cycle-by-cycle, since official documentation for old game consoles was rarely ever public.",
        "Batching many small files into one archive before compressing usually beats compressing each file separately — the compressor gets more repeated patterns to work with.",
        "The .gz extension always compresses a single stream — that's why compressing a whole folder with gzip means tarring it first (.tar.gz).",
        "PNG images are actually zlib-compressed internally — the same compression family as ZIP, just wrapped around image data instead of arbitrary files.",
        "A ZIP file's directory listing lives at the END of the file, not the start — that's exactly why appending files to an existing ZIP is fast: nothing before that point needs to move.",
        "The GBA's official specs never included a home button — every game was expected to have its own way back to the cartridge menu, or none at all.",
        "Huffman coding (part of Deflate) works by giving common symbols shorter codes and rare ones longer codes — it's the same core idea Morse code uses.",
        "DSiWare titles were digital-only downloads for the DSi — there was never a physical cartridge format for them at all.",
        "7-Zip's LZMA2 format splits data into independently compressed chunks specifically so multi-threaded compressors can work on them in parallel.",
        "The GBA's screen resolution (240×160) is exactly 2.5x smaller than the original Game Boy's screen scaled proportionally would suggest — it was a genuinely new panel design, not just an upscale.",
        "RLE (run-length encoding), one of the simplest compression ideas, predates computers — it's essentially how telegraph operators shorthanded repeated symbols.",
    ]

    public init() {}

    /// A pseudo-random fact from the list, distinct from the fact `avoiding`
    /// (when given) — used to guarantee no back-to-back repeat while the
    /// carousel cycles during a long job.
    public func nextFact(avoiding previous: String? = nil) -> String {
        guard let previous, Self.facts.count > 1 else {
            return Self.facts.randomElement() ?? ""
        }
        var candidate = Self.facts.randomElement() ?? ""
        var attempts = 0
        while candidate == previous && attempts < 10 {
            candidate = Self.facts.randomElement() ?? ""
            attempts += 1
        }
        return candidate
    }
}
