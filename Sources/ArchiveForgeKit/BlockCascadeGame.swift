import Foundation

/// A small, original falling-block puzzle engine for the anti-boredom
/// layer — the genre's core mechanic (a grid, polyomino pieces falling
/// under gravity, clearing a full row) is a generic, decades-old
/// recreational-math concept older than any specific commercial game built
/// on it, and this is a clean-room implementation: its own shapes, its own
/// rules, its own code, no borrowed name or branding. Deliberately not
/// called "Tetris" anywhere — that specific name and its official visual
/// style are trademarked/protected by The Tetris Company, and the point
/// here is a quick, honest, original diversion, not a lookalike of anyone
/// else's commercial product.
public struct BlockCascadeGame: Sendable {
    public struct Piece: Sendable {
        /// Relative (col, row) offsets from the piece's own origin — a
        /// generic four-cell polyomino, one of the small set of shapes that
        /// tile a grid without gaps.
        let cells: [(Int, Int)]
        var originCol: Int
        var originRow: Int

        func occupiedCells() -> [(Int, Int)] {
            cells.map { (originCol + $0.0, originRow + $0.1) }
        }
    }

    private static let shapes: [[(Int, Int)]] = [
        [(0, 0), (1, 0), (2, 0), (3, 0)],   // straight four
        [(0, 0), (1, 0), (0, 1), (1, 1)],   // square
        [(0, 0), (1, 0), (2, 0), (1, 1)],   // T-shape
        [(0, 0), (1, 0), (2, 0), (2, 1)],   // corner (long side + short foot)
        [(0, 0), (1, 0), (2, 0), (0, 1)],   // corner, mirrored
        [(1, 0), (2, 0), (0, 1), (1, 1)],   // offset step
        [(0, 0), (1, 0), (1, 1), (2, 1)],   // offset step, mirrored
    ]

    public let width: Int
    public let height: Int
    public private(set) var board: [[Bool]]
    public private(set) var currentPiece: Piece?
    public private(set) var linesCleared = 0
    public private(set) var score = 0
    public private(set) var isGameOver = false

    private var rng: SeededGenerator

    public init(seed: UInt64, width: Int = 10, height: Int = 20) {
        self.width = width
        self.height = height
        self.board = Array(repeating: Array(repeating: false, count: width), count: height)
        self.rng = SeededGenerator(seed: seed)
        spawnPiece()
    }

    private mutating func spawnPiece() {
        let shape = Self.shapes.randomElement(using: &rng) ?? Self.shapes[0]
        let width = shape.map(\.0).max()! + 1
        let piece = Piece(cells: shape, originCol: (self.width - width) / 2, originRow: 0)
        if collides(piece) {
            isGameOver = true
            currentPiece = nil
        } else {
            currentPiece = piece
        }
    }

    private func collides(_ piece: Piece) -> Bool {
        for (col, row) in piece.occupiedCells() {
            if col < 0 || col >= width || row < 0 || row >= height { return true }
            if board[row][col] { return true }
        }
        return false
    }

    public mutating func moveLeft() { attemptMove(dCol: -1, dRow: 0) }
    public mutating func moveRight() { attemptMove(dCol: 1, dRow: 0) }

    private mutating func attemptMove(dCol: Int, dRow: Int) {
        guard var piece = currentPiece, !isGameOver else { return }
        piece.originCol += dCol
        piece.originRow += dRow
        guard !collides(piece) else { return }
        currentPiece = piece
    }

    /// Rotates 90° by reflecting each cell's offset — simple and correct for
    /// this engine's purposes; not attempting wall-kick nuance real
    /// commercial implementations tune extensively, since this is a
    /// five-minute diversion, not the main feature.
    public mutating func rotate() {
        guard let piece = currentPiece, !isGameOver else { return }
        let rotatedCells = piece.cells.map { (col, row) in (-row, col) }
        let minCol = rotatedCells.map(\.0).min() ?? 0
        let minRow = rotatedCells.map(\.1).min() ?? 0
        let normalized = rotatedCells.map { ($0.0 - minCol, $0.1 - minRow) }
        let rotated = Piece(cells: normalized, originCol: piece.originCol, originRow: piece.originRow)
        guard !collides(rotated) else { return }
        currentPiece = rotated
    }

    public mutating func softDrop() {
        guard var piece = currentPiece, !isGameOver else { return }
        piece.originRow += 1
        if collides(piece) {
            lockPieceAndAdvance()
        } else {
            currentPiece = piece
        }
    }

    public mutating func hardDrop() {
        guard var piece = currentPiece, !isGameOver else { return }
        while true {
            var moved = piece
            moved.originRow += 1
            if collides(moved) { break }
            piece = moved
        }
        currentPiece = piece
        lockPieceAndAdvance()
    }

    private mutating func lockPieceAndAdvance() {
        guard let piece = currentPiece else { return }
        for (col, row) in piece.occupiedCells() {
            guard row >= 0 && row < height && col >= 0 && col < width else { continue }
            board[row][col] = true
        }
        clearFullLines()
        spawnPiece()
    }

    private mutating func clearFullLines() {
        var remaining = board.filter { row in row.contains(false) }
        let cleared = height - remaining.count
        guard cleared > 0 else { return }
        linesCleared += cleared
        // Simple, generic scoring curve — clearing several lines in one drop
        // scores more than the same lines cleared separately.
        score += [0, 100, 300, 500, 800][min(cleared, 4)]
        let blankRows = Array(repeating: Array(repeating: false, count: width), count: cleared)
        remaining.insert(contentsOf: blankRows, at: 0)
        board = remaining
    }
}

/// A tiny deterministic PRNG (splitmix64) — not cryptographic, just seedable
/// so the smoke test/tests can reproduce a specific game deterministically
/// instead of depending on true randomness.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
