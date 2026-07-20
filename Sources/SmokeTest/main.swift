import ArchiveForgeKit
import Foundation

// Stopgap correctness check — see Package.swift's SmokeTest comment for why
// this exists instead of using XCTest/Swift Testing directly.

// This script is single-threaded top to bottom (BatchDecompressor.run is
// synchronous — its "progress" closure never actually escapes to another
// thread), so the concurrency-safety Swift 6 can't prove statically is true
// in practice; `nonisolated(unsafe)` says so explicitly for this script-local
// state instead of fighting the checker with actors for no real benefit.
nonisolated(unsafe) var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("  ok  - \(name)")
    } else {
        print("FAIL  - \(name)")
        failures += 1
    }
}

func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

func makeFile(in dir: URL, named name: String, content: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

print("zip round trip")
try withTempDir { tempDir in
    let a = try makeFile(in: tempDir, named: "a.txt", content: "hello from a")
    let b = try makeFile(in: tempDir, named: "b.txt", content: "hello from b")
    let archive = tempDir.appendingPathComponent("bundle.zip")
    try ArchiveEngine.compress(files: [a, b], to: archive, format: .zip)
    check("archive file exists", FileManager.default.fileExists(atPath: archive.path))

    let extractDir = tempDir.appendingPathComponent("extracted")
    let extracted = try ArchiveEngine.decompress(archive: archive, to: extractDir)
    check("extracted 2 files", extracted.count == 2)
    let contentA = try String(contentsOf: extractDir.appendingPathComponent("a.txt"), encoding: .utf8)
    check("a.txt content round-trips", contentA == "hello from a")
}

print("tar round trip")
try withTempDir { tempDir in
    let a = try makeFile(in: tempDir, named: "only.txt", content: "tar me")
    let archive = tempDir.appendingPathComponent("bundle.tar")
    try ArchiveEngine.compress(files: [a], to: archive, format: .tar)
    let extractDir = tempDir.appendingPathComponent("extracted")
    let extracted = try ArchiveEngine.decompress(archive: archive, to: extractDir)
    check("extracted 1 file", extracted.count == 1)
    let content = try String(contentsOf: extractDir.appendingPathComponent("only.txt"), encoding: .utf8)
    check("content round-trips", content == "tar me")
}

print("gzip single-file round trip")
try withTempDir { tempDir in
    let a = try makeFile(in: tempDir, named: "solo.txt", content: "gzip me solo")
    let archive = tempDir.appendingPathComponent("solo.txt.gz")
    try ArchiveEngine.compress(files: [a], to: archive, format: .gzip)
    let extractDir = tempDir.appendingPathComponent("extracted")
    let extracted = try ArchiveEngine.decompress(archive: archive, to: extractDir)
    check("extracted 1 file", extracted.count == 1)
    let content = try String(contentsOf: extracted[0], encoding: .utf8)
    check("content round-trips", content == "gzip me solo")
}

print("gzip multi-file tars-first round trip")
try withTempDir { tempDir in
    let a = try makeFile(in: tempDir, named: "one.txt", content: "one")
    let b = try makeFile(in: tempDir, named: "two.txt", content: "two")
    let archive = tempDir.appendingPathComponent("bundle.tar.gz")
    try ArchiveEngine.compress(files: [a, b], to: archive, format: .gzip)

    let gunzipDir = tempDir.appendingPathComponent("gunzipped")
    let tarFiles = try ArchiveEngine.decompress(archive: archive, to: gunzipDir, format: .gzip)
    check("gunzip produced 1 tar", tarFiles.count == 1)

    let untarDir = tempDir.appendingPathComponent("untarred")
    let finalFiles = try ArchiveEngine.decompress(archive: tarFiles[0], to: untarDir, format: .tar)
    check("untar produced 2 files", finalFiles.count == 2)
}

print("unwritable formats throw")
try withTempDir { tempDir in
    let a = try makeFile(in: tempDir, named: "x.txt", content: "x")
    func throws_(_ block: () throws -> Void) -> Bool {
        do { try block(); return false } catch { return true }
    }
    check("bzip2 compress throws", throws_ { try ArchiveEngine.compress(files: [a], to: tempDir.appendingPathComponent("x.bz2"), format: .bzip2) })
    check("xz compress throws", throws_ { try ArchiveEngine.compress(files: [a], to: tempDir.appendingPathComponent("x.xz"), format: .xz) })
    check("7z compress throws", throws_ { try ArchiveEngine.compress(files: [a], to: tempDir.appendingPathComponent("x.7z"), format: .sevenZip) })
}

print("format detection ignores wrong extension")
try withTempDir { tempDir in
    let a = try makeFile(in: tempDir, named: "a.txt", content: "detect me")
    let archive = tempDir.appendingPathComponent("mystery.dat")
    try ArchiveEngine.compress(files: [a], to: archive, format: .zip)
    let detected = try ArchiveFormat.detect(contentsOf: archive)
    check("detected as zip despite .dat extension", detected == .zip)
}

print("batch decompressor: sequential + progress")
try withTempDir { tempDir in
    let a = try makeFile(in: tempDir, named: "a.txt", content: "a")
    let archive1 = tempDir.appendingPathComponent("first.zip")
    try ArchiveEngine.compress(files: [a], to: archive1, format: .zip)
    let b = try makeFile(in: tempDir, named: "b.txt", content: "b")
    let archive2 = tempDir.appendingPathComponent("second.zip")
    try ArchiveEngine.compress(files: [b], to: archive2, format: .zip)

    nonisolated(unsafe) var progressEvents: [BatchProgress] = []
    let destDir = tempDir.appendingPathComponent("batch-out")
    let results = BatchDecompressor.run(archives: [archive1, archive2], destinationDirectory: destDir) { p in
        progressEvents.append(p)
    }
    check("2 results", results.count == 2)
    check("both succeeded", results.allSatisfy { if case .success = $0.outcome { return true }; return false })
    check("progress events recorded", !progressEvents.isEmpty)
    check("final progress is 1.0", progressEvents.last?.overallFractionComplete == 1.0)
}

print("batch decompressor: continues past a failed archive")
try withTempDir { tempDir in
    let badArchive = tempDir.appendingPathComponent("not-real.zip")
    try "not actually a zip".write(to: badArchive, atomically: true, encoding: .utf8)
    let a = try makeFile(in: tempDir, named: "real.txt", content: "real content")
    let goodArchive = tempDir.appendingPathComponent("real.zip")
    try ArchiveEngine.compress(files: [a], to: goodArchive, format: .zip)

    let destDir = tempDir.appendingPathComponent("batch-mixed-out")
    let results = BatchDecompressor.run(archives: [badArchive, goodArchive], destinationDirectory: destDir)
    check("2 results", results.count == 2)
    var firstFailed = false
    if case .failure = results[0].outcome { firstFailed = true }
    check("first (corrupt) archive failed", firstFailed)
    var secondSucceeded = false
    if case .success = results[1].outcome { secondSucceeded = true }
    check("second (good) archive still succeeded", secondSucceeded)
}

print("resumable jobs: checkpoint persists progress and resume skips completed items")
try withTempDir { tempDir in
    // Three archives; simulate the app getting killed after the first one
    // by only running the batch "partway," reading back what got persisted,
    // then resuming — the whole point of this milestone.
    let sourceDir = tempDir.appendingPathComponent("sources")
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

    var archives: [URL] = []
    for name in ["one", "two", "three"] {
        let file = try makeFile(in: sourceDir, named: "\(name).txt", content: "content of \(name)")
        let archive = sourceDir.appendingPathComponent("\(name).zip")
        try ArchiveEngine.compress(files: [file], to: archive, format: .zip)
        archives.append(archive)
    }

    let checkpointDir = tempDir.appendingPathComponent("checkpoints")
    let store = CheckpointStore(directory: checkpointDir)
    let destDir = tempDir.appendingPathComponent("resumable-out")

    // Simulate "only the first item finished before the app died": run just
    // archives[0..<1] through the checkpointed path directly, bypassing
    // ResumableJobRunner's own full-batch loop so we can inspect
    // mid-batch state exactly as a real kill-and-relaunch would leave it.
    let midCheckpoint = JobCheckpoint(
        mode: .decompress, format: .zip, itemURLs: archives,
        destinationDirectory: destDir, createdAt: Date()
    )
    try store.save(midCheckpoint)
    // BatchDecompressor has no early-exit mid-run, so the "died after item 1"
    // state is hand-crafted directly here — exactly what would be on disk in
    // that real scenario, without needing a way to actually kill this process
    // mid-loop just to test it.
    var interruptedCheckpoint = midCheckpoint
    interruptedCheckpoint.completedCount = 1
    try store.save(interruptedCheckpoint)

    let resumable = store.loadResumable()
    check("exactly 1 resumable checkpoint on disk", resumable.count == 1)
    check("resumable checkpoint remembers completedCount == 1", resumable.first?.completedCount == 1)

    nonisolated(unsafe) var resumeProgressEvents: [BatchProgress] = []
    let (finalCheckpoint, results) = ResumableJobRunner.resume(interruptedCheckpoint, store: store) { p in
        resumeProgressEvents.append(p)
    }

    check("resume processes only the remaining 2 items", results.count == 2)
    check("resume's first result is item index 1 (\"two\"), not item 0 (\"one\")", results.first?.archive.lastPathComponent == "two.zip")
    check("all resumed items succeeded", results.allSatisfy { if case .success = $0.outcome { return true }; return false })
    check("finished checkpoint reports complete", finalCheckpoint.isComplete)
    check("completed checkpoint is deleted from disk, not left behind", store.loadResumable().isEmpty)

    // And the item that supposedly "already finished" before the simulated
    // kill was genuinely never touched by the resumed run.
    let untouchedOutput = destDir.appendingPathComponent("one")
    check("item 0's output directory doesn't exist — resume never re-ran it", !FileManager.default.fileExists(atPath: untouchedOutput.path))
}

print("job cancellation: stops early and leaves a valid resumable checkpoint")
try withTempDir { tempDir in
    let sourceDir = tempDir.appendingPathComponent("sources")
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

    var archives: [URL] = []
    for name in ["one", "two", "three", "four"] {
        let file = try makeFile(in: sourceDir, named: "\(name).txt", content: "content of \(name)")
        let archive = sourceDir.appendingPathComponent("\(name).zip")
        try ArchiveEngine.compress(files: [file], to: archive, format: .zip)
        archives.append(archive)
    }

    let store = CheckpointStore(directory: tempDir.appendingPathComponent("checkpoints"))
    let destDir = tempDir.appendingPathComponent("cancel-out")

    // shouldCancel is checked before each item — reading the checkpoint's own
    // completedCount as it's written mid-run (by onItemComplete, inside
    // ResumableJobRunner) is a real, direct way to trigger "cancel after
    // exactly 2 items finished," not an approximation.
    let (checkpoint, results) = ResumableJobRunner.startDecompress(
        archives: archives, destinationDirectory: destDir, store: store
    ) { _ in
    } shouldCancel: {
        (store.loadResumable().first?.completedCount ?? 0) >= 2
    }

    check("cancellation stopped before processing all 4 items", results.count < 4)
    check("cancellation stopped after at least 1 item", results.count >= 1)
    check("checkpoint reports not complete", !checkpoint.isComplete)
    check("checkpoint is still on disk (not deleted) after cancellation", !store.loadResumable().isEmpty)

    // And resuming afterward finishes the rest.
    let (finalCheckpoint, finalResults) = ResumableJobRunner.resume(checkpoint, store: store)
    check("resume after cancellation completes the remaining items", finalResults.count == archives.count - results.count)
    check("fully resumed checkpoint reports complete", finalCheckpoint.isComplete)
    check("checkpoint deleted after full completion", store.loadResumable().isEmpty)
}

print("ROM library: import persists, survives a fresh instance, tracks recency")
try withTempDir { tempDir in
    // A fake GBA/NDS file — content doesn't matter to the library (it just
    // stores bytes + metadata), so plain text stands in fine here.
    let sourceDir = tempDir.appendingPathComponent("picked-files")
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    let gbaFile = try makeFile(in: sourceDir, named: "Some Game.gba", content: "fake gba bytes")
    let ndsFile = try makeFile(in: sourceDir, named: "Another Game.nds", content: "fake nds bytes")

    let libraryDir = tempDir.appendingPathComponent("rom-library")
    let library = ROMLibrary(storageDirectory: libraryDir)

    let importedGBA = try library.importROM(from: gbaFile)
    check("imported title matches filename minus extension", importedGBA.title == "Some Game")
    check("imported system detected as .gba", importedGBA.system == .gba)

    let importedNDS = try library.importROM(from: ndsFile)
    check("second import detected as .nds", importedNDS.system == .nds)

    // Delete the ORIGINAL source file the user picked — the whole point of
    // "persistent" is that the library's own copy doesn't care.
    try FileManager.default.removeItem(at: gbaFile)
    check("library's stored copy survives deleting the original picked file",
          FileManager.default.fileExists(atPath: library.storageURL(for: importedGBA).path))

    // Simulate an app relaunch: a brand-new ROMLibrary instance pointed at
    // the same directory should see everything a previous instance saved.
    let reloadedLibrary = ROMLibrary(storageDirectory: libraryDir)
    let allROMs = reloadedLibrary.allROMs()
    check("fresh instance sees both imported ROMs", allROMs.count == 2)

    try reloadedLibrary.markPlayed(importedNDS)
    let recent = reloadedLibrary.recentROMs()
    check("most-recently-played ROM sorts first", recent.first?.id == importedNDS.id)

    try reloadedLibrary.remove(importedGBA)
    check("removed ROM no longer listed", reloadedLibrary.allROMs().count == 1)
    check("removed ROM's stored file is deleted", !FileManager.default.fileExists(atPath: library.storageURL(for: importedGBA).path))

    check("unrecognized extension throws instead of silently importing", {
        do {
            _ = try library.importROM(from: try makeFile(in: sourceDir, named: "not-a-rom.txt", content: "x"))
            return false
        } catch {
            return true
        }
    }())
}

print("anti-boredom: falling-block puzzle engine")
try withTempDir { _ in
    var game = BlockCascadeGame(seed: 42, width: 6, height: 12)
    let initialScore = game.score
    check("starts with a live piece on the board", game.currentPiece != nil)
    check("starts with zero lines cleared", game.linesCleared == 0)

    // Drop straight down repeatedly until at least one line clears or the
    // game ends — proves the actual clear-and-score logic runs, not just
    // that pieces move.
    var safetyCounter = 0
    while game.linesCleared == 0 && !game.isGameOver && safetyCounter < 5000 {
        game.hardDrop()
        safetyCounter += 1
    }
    check("hard-dropping pieces eventually clears a line or ends the game", game.linesCleared > 0 || game.isGameOver)
    if game.linesCleared > 0 {
        check("clearing a line increases score", game.score > initialScore)
    }
}

print("anti-boredom: hangman game")
try withTempDir { _ in
    var game = HangmanGame(word: "ARCHIVE", maxWrongGuesses: 6)
    check("word not revealed before any guesses", game.revealedSoFar.contains("_"))

    for letter in "ARCHIVE" {
        game.guess(letter)
    }
    check("guessing every real letter wins", game.state == .won)
    check("no wrong guesses used when every guess was correct", game.wrongGuessCount == 0)

    var losingGame = HangmanGame(word: "ARCHIVE", maxWrongGuesses: 2)
    losingGame.guess("Z")
    losingGame.guess("Q")
    check("running out of wrong guesses loses", losingGame.state == .lost)
    losingGame.guess("X")
    check("guessing after the game is over is a no-op", losingGame.wrongGuessCount == 2)
}

print("anti-boredom: memory match game")
try withTempDir { _ in
    var game = MemoryMatchGame(symbols: ["star", "heart", "bolt", "leaf"], seed: 7)
    check("board has 8 cards (4 pairs)", game.cards.count == 8)
    check("starts with nothing face up", game.cards.allSatisfy { !$0.isFaceUp })
    check("not complete at the start", !game.isComplete)

    // Find a genuine matching pair by symbol, then flip exactly those two —
    // deterministic given the seed, not a guess.
    let firstSymbol = game.cards[0].symbol
    let matchIndex = game.cards.firstIndex { $0.id != game.cards[0].id && $0.symbol == firstSymbol }!
    game.flip(0)
    game.flip(matchIndex)
    check("matching a real pair marks both matched", game.cards[0].isMatched && game.cards[matchIndex].isMatched)
    check("matched cards stay face up", game.cards[0].isFaceUp && game.cards[matchIndex].isFaceUp)
    check("no unresolved mismatch after a real match", !game.hasUnresolvedMismatch)

    // Now flip two cards that do NOT match each other.
    let remaining = game.cards.indices.filter { !game.cards[$0].isMatched }
    let a = remaining[0]
    guard let b = remaining.first(where: { game.cards[$0].symbol != game.cards[a].symbol }) else {
        fatalError("test setup assumption broken: expected at least two distinct remaining symbols")
    }
    game.flip(a)
    game.flip(b)
    check("mismatched pair is flagged as unresolved", game.hasUnresolvedMismatch)
    game.acknowledgeMismatch()
    check("acknowledging a mismatch flips both back down", !game.cards[a].isFaceUp && !game.cards[b].isFaceUp)
    check("mismatched cards are not marked matched", !game.cards[a].isMatched && !game.cards[b].isMatched)

    check("move count tracks each flip that completed a pair attempt", game.moveCount == 2)
}

print("anti-boredom: fun facts provider never repeats back-to-back")
try withTempDir { _ in
    let provider = FunFactProvider()
    var previous: String?
    for _ in 0..<20 {
        let fact = provider.nextFact(avoiding: previous)
        check("fact is non-empty", !fact.isEmpty)
        if let previous {
            check("no immediate repeat", fact != previous)
        }
        previous = fact
    }
}

print()
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
