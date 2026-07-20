import Foundation

/// The boundary a real GBA/NDS core would implement to actually run a ROM
/// from the library. Same shape as WizardiOS's own `EmulatorCore` protocol —
/// deliberately: a real cycle-accurate core is a large, separate
/// undertaking (WizardiOS itself is still "foundation complete, cores
/// stubbed" despite being its own dedicated project), so this milestone
/// wires the architecture and ships `StubCore` as the placeholder, the same
/// honest way WizardiOS does, rather than claiming emulation works when it
/// doesn't yet.
public protocol EmulatorCore: Sendable {
    var system: ROMSystem { get }
    mutating func loadGame(from url: URL) throws
    mutating func runFrame() -> VideoFrame
    mutating func setInput(_ state: PadState)
}

public struct VideoFrame: Sendable {
    public let width: Int
    public let height: Int
    /// RGBA8888, row-major — a real core fills this from actual emulated
    /// PPU/GPU output; the stub below fills it with a fixed test pattern.
    public let pixels: [UInt8]
}

public struct PadState: Sendable, Equatable {
    public var up = false, down = false, left = false, right = false
    public var a = false, b = false, start = false, select = false
    public init() {}
}

public enum EmulatorCoreError: Error, LocalizedError, Sendable {
    case unsupportedSystem(ROMSystem)
    case romNotFound

    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem(let system): return "No emulator core is wired up for \(system.rawValue.uppercased()) yet."
        case .romNotFound: return "That ROM's file couldn't be found in the library's storage."
        }
    }
}

/// Placeholder core — renders a fixed, recognizable test pattern instead of
/// real gameplay. Exists so every other layer (the anti-boredom UI, the
/// library, the "play a ROM" flow) can be built and verified now, with a
/// real mGBA/melonDS-backed core swapped in later without changing any of
/// those call sites.
public struct StubCore: EmulatorCore {
    public let system: ROMSystem
    private var loadedROMURL: URL?
    private var frameCounter: UInt64 = 0

    public init(system: ROMSystem) {
        self.system = system
    }

    public mutating func loadGame(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EmulatorCoreError.romNotFound
        }
        loadedROMURL = url
        frameCounter = 0
    }

    public mutating func runFrame() -> VideoFrame {
        frameCounter += 1
        let width = 32, height = 24 // arbitrary small test-pattern resolution
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // A slowly shifting diagonal stripe pattern — enough to visibly prove
        // "a frame is being generated every call" without pretending to be
        // real emulated video.
        let shift = Int(frameCounter % UInt64(width))
        for row in 0..<height {
            for col in 0..<width {
                let isStripe = (col + row + shift) % 8 < 4
                let index = (row * width + col) * 4
                let value: UInt8 = isStripe ? 200 : 40
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
                pixels[index + 3] = 255
            }
        }
        return VideoFrame(width: width, height: height, pixels: pixels)
    }

    public mutating func setInput(_ state: PadState) {
        // No real CPU/PPU to react to input yet — accepted and ignored.
    }
}
