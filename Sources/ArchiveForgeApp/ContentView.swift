import ArchiveForgeKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var viewModel = JobQueueViewModel()
    @State private var isTargetedForDrop = false
    @State private var showingFileImporter = false
    @State private var showingROMLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            if let checkpoint = viewModel.resumableCheckpoint {
                resumeBanner(for: checkpoint)
                Divider()
            }
            header
            Divider()
            if viewModel.isRunning {
                AntiBoredomOverlay(romLibrary: viewModel.romLibrary)
            } else if viewModel.items.isEmpty {
                dropZone
            } else {
                queueList
            }
            Divider()
            footer
        }
        .background(.background)
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                viewModel.addFiles(urls)
                viewModel.importROMsIfApplicable(from: urls)
            }
        }
        .sheet(isPresented: $showingROMLibrary) {
            ROMLibraryView(romLibrary: viewModel.romLibrary)
        }
    }

    // MARK: - Resume banner

    /// Shown when a previous run left an unfinished job on disk — a
    /// background suspension that ran out of extension time, a force-quit,
    /// or a crash. This is the actual payoff of milestone 2: instead of
    /// silently losing that progress, the user gets a one-tap way to
    /// continue exactly where it left off.
    private func resumeBanner(for checkpoint: JobCheckpoint) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unfinished job found")
                    .font(.subheadline.weight(.semibold))
                Text("\(checkpoint.completedCount) of \(checkpoint.itemURLs.count) items done — pick up where it left off?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Discard") { viewModel.discardResumableJob() }
                .buttonStyle(.bordered)
            Button("Resume") { viewModel.resumeInterruptedJob() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.orange.opacity(0.1))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("ArchiveForge")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    showingROMLibrary = true
                } label: {
                    Image(systemName: "square.stack.3d.up.fill")
                }
                .help("Your ROM Library")
            }
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(JobMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.mode == .compress {
                HStack {
                    Text("Format")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Format", selection: $viewModel.format) {
                        ForEach(ArchiveFormat.allCases.filter(\.canWrite), id: \.self) { format in
                            Text(".\(format.fileExtension)").tag(format)
                        }
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Drop zone (empty state)

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(viewModel.mode == .decompress ? "Drop archives here" : "Drop files here")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("or")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Choose Files…") { showingFileImporter = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.quaternary.opacity(isTargetedForDrop ? 0.5 : 0.15))
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargetedForDrop ? Color.accentColor : .secondary.opacity(0.4))
                .padding(24)
        )
        .animation(.easeInOut(duration: 0.15), value: isTargetedForDrop)
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    viewModel.addFiles([url])
                    viewModel.importROMsIfApplicable(from: [url])
                }
            }
        }
    }

    // MARK: - Queue list (non-empty state)

    private var queueList: some View {
        List {
            ForEach(viewModel.items) { item in
                QueuedItemRow(item: item)
                    .swipeActions {
                        Button("Remove", role: .destructive) { viewModel.removeItem(item) }
                    }
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .bottom) {
            Button {
                showingFileImporter = true
            } label: {
                Label("Add More", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if viewModel.isRunning {
                ProgressView(value: viewModel.overallFraction)
                    .progressViewStyle(.linear)
                Text("\(Int(viewModel.overallFraction * 100))% overall")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = viewModel.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            HStack {
                Button("Clear Completed") { viewModel.clearCompleted() }
                    .disabled(viewModel.items.isEmpty || viewModel.isRunning)
                Spacer()
                if viewModel.isRunning {
                    Button(role: .destructive) {
                        viewModel.cancel()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle.fill")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        viewModel.start()
                    } label: {
                        Label(viewModel.mode.rawValue, systemImage: viewModel.mode == .decompress ? "arrow.down.doc" : "arrow.up.doc")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.items.isEmpty)
                }
            }
        }
        .padding()
    }
}

private struct QueuedItemRow: View {
    @Bindable var item: QueuedItem

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                if case .running = item.status {
                    ProgressView(value: item.fractionComplete)
                        .progressViewStyle(.linear)
                } else if case .failed(let message) = item.status {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "doc").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

#Preview {
    ContentView()
}
