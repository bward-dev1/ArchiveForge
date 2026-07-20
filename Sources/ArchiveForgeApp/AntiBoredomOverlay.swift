import ArchiveForgeKit
import SwiftUI

/// SF Symbol names for the memory-match cards — plain system icons, not
/// custom art. `MemoryMatchGame` itself only deals in opaque `String`
/// identifiers by design; this is the one place that picks what they mean.
enum MemoryMatchSymbols {
    static let set = ["star.fill", "heart.fill", "bolt.fill", "leaf.fill", "moon.fill", "flame.fill", "drop.fill", "snowflake"]
}

/// Shown while a job is running — the actual "don't just watch a spinner"
/// feature. Cycles between a fun fact, a quick hangman round, the falling-
/// block puzzle, a memory-match round, and — the part that makes this a
/// "core part" rather than a bolt-on, per the brief — jumping back into a
/// ROM already in your persistent library. Real gameplay there is a
/// placeholder (`StubCore`) until a real emulator core is wired in;
/// everything else here is fully working today.
struct AntiBoredomOverlay: View {
    let romLibrary: ROMLibrary
    @State private var selectedActivity: Activity = .funFact
    @State private var currentFact = FunFactProvider().nextFact()
    @State private var hangman = HangmanGame(word: HangmanWordList.words.randomElement() ?? "ARCHIVE")
    @State private var cascade = BlockCascadeGame(seed: UInt64(Date().timeIntervalSince1970))
    @State private var memoryMatch = MemoryMatchGame(symbols: MemoryMatchSymbols.set, seed: UInt64(Date().timeIntervalSince1970))
    @State private var recentROMs: [LoadedROM] = []

    private let factProvider = FunFactProvider()

    enum Activity: String, CaseIterable, Identifiable {
        case funFact = "Fun Fact"
        case hangman = "Hangman"
        case blockCascade = "Blocks"
        case memoryMatch = "Memory"
        case playROM = "Your Library"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("Activity", selection: $selectedActivity) {
                ForEach(Activity.allCases) { activity in
                    Text(activity.rawValue).tag(activity)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedActivity {
                case .funFact: funFactView
                case .hangman: hangmanView
                case .blockCascade: blockCascadeView
                case .memoryMatch: memoryMatchView
                case .playROM: playROMView
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding()
        .onAppear { recentROMs = romLibrary.recentROMs() }
    }

    private var funFactView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .font(.title)
                .foregroundStyle(.yellow)
            Text(currentFact)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Next Fact") { currentFact = factProvider.nextFact(avoiding: currentFact) }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    private var hangmanView: some View {
        VStack(spacing: 12) {
            Text(hangman.revealedSoFar.map(String.init).joined(separator: " "))
                .font(.title2.monospaced())
            Text("Wrong guesses: \(hangman.wrongGuessCount)/\(hangman.maxWrongGuesses)")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch hangman.state {
            case .playing:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
                    ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), id: \.self) { letter in
                        Button(String(letter)) { hangman.guess(letter) }
                            .buttonStyle(.bordered)
                            .disabled(hangman.guessedLetters.contains(letter))
                    }
                }
            case .won:
                Label("Solved it!", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Play Again") { hangman = HangmanGame(word: HangmanWordList.words.randomElement() ?? "ARCHIVE") }
            case .lost:
                Label("The word was \(hangman.word)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                Button("Play Again") { hangman = HangmanGame(word: HangmanWordList.words.randomElement() ?? "ARCHIVE") }
            }
        }
        .padding()
    }

    private var blockCascadeView: some View {
        VStack(spacing: 8) {
            BlockCascadeBoardView(game: cascade)
            Text("Score: \(cascade.score) · Lines: \(cascade.linesCleared)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if cascade.isGameOver {
                Button("New Game") { cascade = BlockCascadeGame(seed: UInt64(Date().timeIntervalSince1970)) }
            } else {
                HStack {
                    Button { cascade.moveLeft() } label: { Image(systemName: "arrow.left.circle.fill") }
                    Button { cascade.rotate() } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                    Button { cascade.moveRight() } label: { Image(systemName: "arrow.right.circle.fill") }
                    Button { cascade.hardDrop() } label: { Image(systemName: "arrow.down.to.line.circle.fill") }
                }
                .font(.title2)
            }
        }
        .padding()
    }

    private var memoryMatchView: some View {
        VStack(spacing: 10) {
            if memoryMatch.isComplete {
                Label("Solved in \(memoryMatch.moveCount) moves!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Play Again") {
                    memoryMatch = MemoryMatchGame(symbols: MemoryMatchSymbols.set, seed: UInt64(Date().timeIntervalSince1970))
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(memoryMatch.cards) { card in
                        Button {
                            guard !memoryMatch.hasUnresolvedMismatch else { return }
                            memoryMatch.flip(card.id)
                        } label: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(card.isMatched ? Color.green.opacity(0.25) : Color.secondary.opacity(0.15))
                                .frame(height: 44)
                                .overlay {
                                    if card.isFaceUp || card.isMatched {
                                        Image(systemName: card.symbol)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Moves: \(memoryMatch.moveCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onChange(of: memoryMatch.hasUnresolvedMismatch) { _, hasUnresolvedMismatch in
            guard hasUnresolvedMismatch else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                memoryMatch.acknowledgeMismatch()
            }
        }
    }

    private var playROMView: some View {
        Group {
            if recentROMs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("No ROMs in your library yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Load a GBA/NDS file anywhere in the app and it'll show up here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            } else {
                List(recentROMs) { rom in
                    HStack {
                        Image(systemName: rom.system == .gba ? "square.grid.2x2" : "rectangle.split.2x1")
                        VStack(alignment: .leading) {
                            Text(rom.title).font(.subheadline)
                            Text(rom.system.rawValue.uppercased()).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Play") { try? romLibrary.markPlayed(rom) }
                            .buttonStyle(.bordered)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Minimal renderer for `BlockCascadeGame`'s board — plain rectangles, no
/// custom art assets, deliberately generic-looking rather than mimicking any
/// specific commercial game's visual style.
private struct BlockCascadeBoardView: View {
    let game: BlockCascadeGame

    var body: some View {
        GeometryReader { geo in
            let cellSize = min(geo.size.width / CGFloat(game.width), geo.size.height / CGFloat(game.height))
            ZStack(alignment: .topLeading) {
                ForEach(0..<game.height, id: \.self) { row in
                    ForEach(0..<game.width, id: \.self) { col in
                        Rectangle()
                            .fill(game.board[row][col] ? Color.accentColor : Color.secondary.opacity(0.08))
                            .frame(width: cellSize - 1, height: cellSize - 1)
                            .position(x: CGFloat(col) * cellSize + cellSize / 2, y: CGFloat(row) * cellSize + cellSize / 2)
                    }
                }
                if let piece = game.currentPiece {
                    ForEach(Array(piece.occupiedCells().enumerated()), id: \.offset) { _, cell in
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: cellSize - 1, height: cellSize - 1)
                            .position(x: CGFloat(cell.0) * cellSize + cellSize / 2, y: CGFloat(cell.1) * cellSize + cellSize / 2)
                    }
                }
            }
        }
        .aspectRatio(CGFloat(game.width) / CGFloat(game.height), contentMode: .fit)
        .frame(maxHeight: 160)
    }
}
