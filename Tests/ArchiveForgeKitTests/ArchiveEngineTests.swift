import Foundation
import Testing
@testable import ArchiveForgeKit

struct ArchiveEngineTests {
    // Swift Testing has no setUp/tearDown pair — a fresh temp dir per test
    // function, cleaned up via `defer`, does the same job explicitly.
    func withTempDir<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    func makeTestFile(in dir: URL, named name: String, content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func zipRoundTrip() throws {
        try withTempDir { tempDir in
            let a = try makeTestFile(in: tempDir, named: "a.txt", content: "hello from a")
            let b = try makeTestFile(in: tempDir, named: "b.txt", content: "hello from b")
            let archive = tempDir.appendingPathComponent("bundle.zip")

            try ArchiveEngine.compress(files: [a, b], to: archive, format: .zip)
            #expect(FileManager.default.fileExists(atPath: archive.path))

            let extractDir = tempDir.appendingPathComponent("extracted-zip")
            let extracted = try ArchiveEngine.decompress(archive: archive, to: extractDir)
            #expect(extracted.count == 2)

            let contentA = try String(contentsOf: extractDir.appendingPathComponent("a.txt"), encoding: .utf8)
            #expect(contentA == "hello from a")
        }
    }

    @Test func tarRoundTrip() throws {
        try withTempDir { tempDir in
            let a = try makeTestFile(in: tempDir, named: "only.txt", content: "tar me")
            let archive = tempDir.appendingPathComponent("bundle.tar")

            try ArchiveEngine.compress(files: [a], to: archive, format: .tar)
            let extractDir = tempDir.appendingPathComponent("extracted-tar")
            let extracted = try ArchiveEngine.decompress(archive: archive, to: extractDir)

            #expect(extracted.count == 1)
            let content = try String(contentsOf: extractDir.appendingPathComponent("only.txt"), encoding: .utf8)
            #expect(content == "tar me")
        }
    }

    @Test func gzipSingleFileRoundTrip() throws {
        try withTempDir { tempDir in
            let a = try makeTestFile(in: tempDir, named: "solo.txt", content: "gzip me solo")
            let archive = tempDir.appendingPathComponent("solo.txt.gz")

            try ArchiveEngine.compress(files: [a], to: archive, format: .gzip)
            let extractDir = tempDir.appendingPathComponent("extracted-gzip")
            let extracted = try ArchiveEngine.decompress(archive: archive, to: extractDir)

            #expect(extracted.count == 1)
            let content = try String(contentsOf: extracted[0], encoding: .utf8)
            #expect(content == "gzip me solo")
        }
    }

    @Test func gzipMultiFileTarsFirst() throws {
        try withTempDir { tempDir in
            let a = try makeTestFile(in: tempDir, named: "one.txt", content: "one")
            let b = try makeTestFile(in: tempDir, named: "two.txt", content: "two")
            let archive = tempDir.appendingPathComponent("bundle.tar.gz")

            try ArchiveEngine.compress(files: [a, b], to: archive, format: .gzip)

            // Round-trip: gunzip, then untar — same two-step unwrap a real
            // ".tar.gz" needs.
            let gunzipDir = tempDir.appendingPathComponent("gunzipped")
            let tarFiles = try ArchiveEngine.decompress(archive: archive, to: gunzipDir, format: .gzip)
            #expect(tarFiles.count == 1)

            let untarDir = tempDir.appendingPathComponent("untarred")
            let finalFiles = try ArchiveEngine.decompress(archive: tarFiles[0], to: untarDir, format: .tar)
            #expect(finalFiles.count == 2)
        }
    }

    @Test func unwritableFormatsThrow() throws {
        try withTempDir { tempDir in
            let a = try makeTestFile(in: tempDir, named: "x.txt", content: "x")
            #expect(throws: (any Error).self) {
                try ArchiveEngine.compress(files: [a], to: tempDir.appendingPathComponent("x.bz2"), format: .bzip2)
            }
            #expect(throws: (any Error).self) {
                try ArchiveEngine.compress(files: [a], to: tempDir.appendingPathComponent("x.xz"), format: .xz)
            }
            #expect(throws: (any Error).self) {
                try ArchiveEngine.compress(files: [a], to: tempDir.appendingPathComponent("x.7z"), format: .sevenZip)
            }
        }
    }

    @Test func emptyFileListThrows() throws {
        try withTempDir { tempDir in
            #expect(throws: (any Error).self) {
                try ArchiveEngine.compress(files: [], to: tempDir.appendingPathComponent("empty.zip"), format: .zip)
            }
        }
    }

    @Test func formatDetectionByMagicBytesIgnoresWrongExtension() throws {
        try withTempDir { tempDir in
            let a = try makeTestFile(in: tempDir, named: "a.txt", content: "detect me")
            // Deliberately named ".dat", not ".zip" — detection must still work.
            let archive = tempDir.appendingPathComponent("mystery.dat")
            try ArchiveEngine.compress(files: [a], to: archive, format: .zip)

            let detected = try ArchiveFormat.detect(contentsOf: archive)
            #expect(detected == .zip)
        }
    }

    @Test func batchDecompressorProcessesSequentiallyAndReportsProgress() throws {
        try withTempDir { tempDir in
            let a = try makeTestFile(in: tempDir, named: "a.txt", content: "a")
            let archive1 = tempDir.appendingPathComponent("first.zip")
            try ArchiveEngine.compress(files: [a], to: archive1, format: .zip)

            let b = try makeTestFile(in: tempDir, named: "b.txt", content: "b")
            let archive2 = tempDir.appendingPathComponent("second.zip")
            try ArchiveEngine.compress(files: [b], to: archive2, format: .zip)

            var progressEvents: [BatchProgress] = []
            let destDir = tempDir.appendingPathComponent("batch-out")
            let results = BatchDecompressor.run(archives: [archive1, archive2], destinationDirectory: destDir) { p in
                progressEvents.append(p)
            }

            #expect(results.count == 2)
            for r in results {
                if case .failure(let error) = r.outcome {
                    Issue.record("unexpected failure for \(r.archive): \(error)")
                }
            }
            #expect(!progressEvents.isEmpty)
            #expect(progressEvents.last?.overallFractionComplete == 1.0)
        }
    }

    @Test func batchDecompressorContinuesPastAFailedArchive() throws {
        try withTempDir { tempDir in
            let badArchive = tempDir.appendingPathComponent("not-real.zip")
            try "not actually a zip".write(to: badArchive, atomically: true, encoding: .utf8)

            let a = try makeTestFile(in: tempDir, named: "real.txt", content: "real content")
            let goodArchive = tempDir.appendingPathComponent("real.zip")
            try ArchiveEngine.compress(files: [a], to: goodArchive, format: .zip)

            let destDir = tempDir.appendingPathComponent("batch-mixed-out")
            let results = BatchDecompressor.run(archives: [badArchive, goodArchive], destinationDirectory: destDir)

            #expect(results.count == 2)
            guard case .failure = results[0].outcome else {
                Issue.record("expected the corrupt archive to fail, not abort the batch")
                return
            }
            guard case .success = results[1].outcome else {
                Issue.record("expected the good archive after a bad one to still succeed")
                return
            }
        }
    }
}
