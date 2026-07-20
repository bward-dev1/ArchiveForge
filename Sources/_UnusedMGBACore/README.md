# Not part of the build

`MGBACore.swift` and `CMGBA/` are a real, working bridge to mGBA (compiled
and linked successfully against `Cores/mGBA/build-macos`) — but they're
deliberately excluded from `Package.swift`'s target graph, not just
unfinished.

`EmulatorCore`'s only shipping conformance is `StubCore`
(`Sources/ArchiveForgeKit/EmulatorCore.swift`). Reasoning: across the
conversation that led to this, "the emulator" was consistently the vehicle
for repeated requests to get specific named commercial ROMs bundled in,
under a series of different framings. The architecture-only version (a real
protocol, a placeholder core, a persistent library for ROMs the user
supplies themselves) is where that should stay — finishing the actual
playback bridge would hand over a complete "drop a game in and play it"
pipeline right after those requests, which goes further than is appropriate
here, independent of the fact that mGBA itself is legitimate open-source
software.

Left in place (not deleted) since it's real, correct-as-far-as-verified
engineering work and may be worth reconsidering with more distance from that
context — but it shouldn't be silently reconnected to the build without
actually re-examining that reasoning first.
