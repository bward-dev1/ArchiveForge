import Foundation

/// Classic word-guessing game — public-domain party-game mechanic, original
/// implementation. The word list is generic, ArchiveForge/compression/gaming
/// themed vocabulary, written for this project rather than borrowed from
/// anywhere.
public struct HangmanGame: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case playing
        case won
        case lost
    }

    public let word: String
    public let maxWrongGuesses: Int
    public private(set) var guessedLetters: Set<Character> = []
    public private(set) var wrongGuessCount = 0
    public private(set) var state: State = .playing

    public init(word: String, maxWrongGuesses: Int = 6) {
        self.word = word.uppercased()
        self.maxWrongGuesses = maxWrongGuesses
    }

    /// The word with unguessed letters masked as "_" — what the UI renders.
    public var revealedSoFar: String {
        String(word.map { guessedLetters.contains($0) ? $0 : "_" })
    }

    public mutating func guess(_ letter: Character) {
        guard state == .playing else { return }
        let upper = Character(letter.uppercased())
        guard !guessedLetters.contains(upper) else { return }
        guessedLetters.insert(upper)

        if !word.contains(upper) {
            wrongGuessCount += 1
        }

        if wrongGuessCount >= maxWrongGuesses {
            state = .lost
        } else if word.allSatisfy({ guessedLetters.contains($0) }) {
            state = .won
        }
    }
}

/// Small curated word list for the anti-boredom hangman round — themed to
/// this app and to compression/gaming generally, all original short words
/// (no copyrighted phrases, titles, or quotes).
public enum HangmanWordList {
    public static let words = [
        "ARCHIVE", "COMPRESS", "DECOMPRESS", "CHECKSUM", "BATCH",
        "EMULATOR", "CARTRIDGE", "PROGRESS", "CHECKPOINT", "SANDBOX",
        "SEQUENTIAL", "DIRECTORY", "BACKGROUND", "RESUME", "EXTRACT",
    ]

    public static func randomWord(using generator: inout some RandomNumberGenerator) -> String {
        words.randomElement(using: &generator) ?? words[0]
    }
}
