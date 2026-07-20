import Foundation

/// A small card-matching game — flip two cards, keep them face-up if they
/// match, flip back if not. Generic, decades-old party-game mechanic;
/// original implementation, symbols are plain SF Symbol names chosen by the
/// app layer (this type only deals in opaque `String` identifiers).
public struct MemoryMatchGame: Sendable {
    public struct Card: Sendable, Identifiable {
        public let id: Int
        public let symbol: String
        public var isFaceUp: Bool
        public var isMatched: Bool
    }

    public private(set) var cards: [Card]
    public private(set) var moveCount = 0
    private var firstFlippedIndex: Int?

    public var isComplete: Bool {
        cards.allSatisfy(\.isMatched)
    }

    public init(symbols: [String], seed: UInt64) {
        var deck = (symbols + symbols).enumerated().map { index, symbol in
            Card(id: index, symbol: symbol, isFaceUp: false, isMatched: false)
        }
        var rng = SeededGenerator(seed: seed)
        deck.shuffle(using: &rng)
        // Re-assign ids after shuffling so `id` reflects board position, not
        // original symbol-pair order — matters for SwiftUI's ForEach identity.
        self.cards = deck.enumerated().map { index, card in
            Card(id: index, symbol: card.symbol, isFaceUp: false, isMatched: false)
        }
    }

    /// Flips the card at `index`. Returns quickly (no-op) for an already
    /// face-up/matched card, or while two non-matching cards are still
    /// showing and waiting to be flipped back via `acknowledgeMismatch()`.
    public mutating func flip(_ index: Int) {
        guard cards.indices.contains(index) else { return }
        guard !cards[index].isFaceUp, !cards[index].isMatched else { return }

        if let firstIndex = firstFlippedIndex {
            guard firstIndex != index else { return }
            cards[index].isFaceUp = true
            moveCount += 1
            if cards[firstIndex].symbol == cards[index].symbol {
                cards[firstIndex].isMatched = true
                cards[index].isMatched = true
                firstFlippedIndex = nil
            }
            // Mismatch: left face-up on purpose — the caller shows both
            // briefly, then calls acknowledgeMismatch() to flip them back.
            // Doing it as two explicit steps (not a Task.sleep in here) keeps
            // this type fully synchronous and UI-framework-agnostic.
        } else {
            cards[index].isFaceUp = true
            firstFlippedIndex = index
        }
    }

    /// Call after showing a mismatched pair briefly — flips both back down.
    /// A no-op if the two currently face-up cards actually matched (already
    /// resolved and left face-up permanently by `flip`).
    public mutating func acknowledgeMismatch() {
        guard let firstIndex = firstFlippedIndex else { return }
        for index in cards.indices where cards[index].isFaceUp && !cards[index].isMatched {
            cards[index].isFaceUp = false
        }
        firstFlippedIndex = nil
        _ = firstIndex
    }

    /// True right after a flip completes a *mismatched* pair (both face-up,
    /// neither matched) — the UI's cue to pause, then call
    /// `acknowledgeMismatch()`.
    public var hasUnresolvedMismatch: Bool {
        let faceUpUnmatched = cards.filter { $0.isFaceUp && !$0.isMatched }
        return faceUpUnmatched.count == 2
    }
}
