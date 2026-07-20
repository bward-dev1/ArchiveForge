import CMGBA
import Foundation

/// Real `EmulatorCore` conformance backed by mGBA (Cores/mGBA, MPL-2.0),
/// the same open-source core WizardiOS's own roadmap lists as the GBA
/// starting point. This wraps mGBA's actual C API (`mCoreFind`/`mCoreCreate`,
/// `loadROM`, `runFrame`, `setKeys`, `getPixels`) — no Nintendo code, BIOS,
/// or ROM data of any kind lives in this file or anywhere in this repo; the
/// user's own legally-obtained ROM file is supplied at runtime through
/// `loadGame(from:)`, exactly like every other legitimate GBA emulator
/// front-end (mGBA's own official builds included).
///
/// Scope of what's real here: core creation, ROM loading (or correctly
/// rejecting a non-ROM file instead of crashing), and pixel-frame output.
/// Audio and save states are NOT wired yet — that's real further work, not
/// silently skipped: see `Cores/README.md`.
public final class MGBACore: EmulatorCore, @unchecked Sendable {
    public let system: ROMSystem = .gba
    private var core: UnsafeMutablePointer<mCore>?

    public init() {}

    deinit {
        if let core {
            core.pointee.deinit(core)
        }
    }

    public func loadGame(from url: URL) throws {
        guard let created = mCoreCreate(mPLATFORM_GBA) else {
            throw EmulatorCoreError.unsupportedSystem(.gba)
        }
        guard created.pointee.init(created) else {
            throw EmulatorCoreError.unsupportedSystem(.gba)
        }

        guard let vf = url.path.withCString({ VFileOpen($0, O_RDONLY) }) else {
            created.pointee.deinit(created)
            throw EmulatorCoreError.romNotFound
        }
        guard created.pointee.loadROM(created, vf) else {
            created.pointee.deinit(created)
            throw EmulatorCoreError.romNotFound
        }

        created.pointee.reset(created)
        core = created
    }

    public func runFrame() -> VideoFrame {
        guard let core else {
            // No ROM loaded — same test-pattern fallback as StubCore rather
            // than a crash, since a caller asking for a frame before/after
            // a load failure is a real, expected UI state (e.g. the anti-
            // boredom overlay tearing down after `loadGame` throws).
            var stub = StubCore(system: .gba)
            return stub.runFrame()
        }

        var width: CUnsignedInt = 0
        var height: CUnsignedInt = 0
        core.pointee.currentVideoSize(core, &width, &height)
        var buffer = [UInt32](repeating: 0, count: Int(width) * Int(height))
        buffer.withUnsafeMutableBufferPointer { ptr in
            core.pointee.setVideoBuffer(core, ptr.baseAddress, Int(width))
            core.pointee.runFrame(core)
        }

        var pixels = [UInt8](repeating: 0, count: buffer.count * 4)
        for (index, pixel) in buffer.enumerated() {
            // mGBA's mColor is platform-endian ARGB/BGRA depending on build
            // config — byte order here is a real thing that needs verifying
            // against an actual running core (see Cores/README.md); this is
            // a reasonable first assumption, not confirmed against real
            // rendered output yet.
            pixels[index * 4] = UInt8((pixel >> 16) & 0xFF)
            pixels[index * 4 + 1] = UInt8((pixel >> 8) & 0xFF)
            pixels[index * 4 + 2] = UInt8(pixel & 0xFF)
            pixels[index * 4 + 3] = 255
        }
        return VideoFrame(width: Int(width), height: Int(height), pixels: pixels)
    }

    public func setInput(_ state: PadState) {
        guard let core else { return }
        var keys: UInt32 = 0
        if state.a { keys |= 1 << 0 }
        if state.b { keys |= 1 << 1 }
        if state.select { keys |= 1 << 2 }
        if state.start { keys |= 1 << 3 }
        if state.right { keys |= 1 << 4 }
        if state.left { keys |= 1 << 5 }
        if state.up { keys |= 1 << 6 }
        if state.down { keys |= 1 << 7 }
        core.pointee.setKeys(core, keys)
    }
}
