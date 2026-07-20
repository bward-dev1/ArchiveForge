import ArchiveForgeKit
import SwiftUI

/// Full management view for the persistent ROM library — everything the
/// anti-boredom carousel's "Your Library" tab doesn't have room for: every
/// ROM (not just the 5 most recent), removal, and basic metadata (system,
/// added date, last played).
struct ROMLibraryView: View {
    let romLibrary: ROMLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var roms: [LoadedROM] = []
    @State private var systemFilter: ROMSystem?

    private var filteredROMs: [LoadedROM] {
        let sorted = roms.sorted { $0.addedAt > $1.addedAt }
        guard let systemFilter else { return sorted }
        return sorted.filter { $0.system == systemFilter }
    }

    var body: some View {
        NavigationStack {
            Group {
                if roms.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("ROM Library")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                #else
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Filter", selection: $systemFilter) {
                        Text("All").tag(ROMSystem?.none)
                        ForEach(ROMSystem.allCases, id: \.self) { system in
                            Text(system.rawValue.uppercased()).tag(ROMSystem?.some(system))
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .onAppear { roms = romLibrary.allROMs() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No ROMs yet")
                .font(.headline)
            Text("Load a GBA/NDS file anywhere in the app and it'll be saved here automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(filteredROMs) { rom in
                HStack(spacing: 12) {
                    Image(systemName: rom.system == .gba ? "square.grid.2x2" : "rectangle.split.2x1")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rom.title)
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 6) {
                            Text(rom.system.rawValue.uppercased())
                            Text("·")
                            Text("Added \(rom.addedAt.formatted(date: .abbreviated, time: .omitted))")
                            if let lastPlayed = rom.lastPlayedAt {
                                Text("·")
                                Text("Played \(lastPlayed.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { remove(rom) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if filteredROMs.isEmpty {
                ContentUnavailableViewCompat(systemFilter: systemFilter)
            }
        }
    }

    private func remove(_ rom: LoadedROM) {
        try? romLibrary.remove(rom)
        roms.removeAll { $0.id == rom.id }
    }
}

/// `ContentUnavailableView` needs iOS 17/macOS 14, which is this app's exact
/// deployment target — no compatibility shim actually needed, but named
/// distinctly so a future lower deployment-target change doesn't silently
/// break this specific spot without a compile error pointing here.
private struct ContentUnavailableViewCompat: View {
    let systemFilter: ROMSystem?

    var body: some View {
        ContentUnavailableView(
            "No \(systemFilter?.rawValue.uppercased() ?? "") ROMs",
            systemImage: "line.3.horizontal.decrease.circle"
        )
    }
}
