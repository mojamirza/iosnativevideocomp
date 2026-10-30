import SwiftUI
import AVFoundation

/// One imported video on its way into the setup flow (batch-capable).
struct PickedVideo: Identifiable {
    let id = UUID()
    let url: URL
    var thumbnail: UIImage?
}

/// Shown right after picking video(s): probe summary, preset selection with a
/// live *estimated output size / bitrate*, and the Compress button.
/// A batch (N > 1) applies ONE preset to all videos; per-file estimates and
/// totals are shown live. A single video looks exactly like the old flow.
struct SetupFlowView: View {
    @EnvironmentObject private var coordinator: JobCoordinator

    let videos: [PickedVideo]
    let onDone: () -> Void

    @State private var probes: [ProbeResult?]
    @State private var analysisDone = false
    @State private var errorText: String?
    @State private var selectedPreset: Preset?
    @State private var customPresets: [Preset] = PresetStore.loadCustom()
    @State private var showEditor = false
    @State private var editingPreset: Preset?

    var availablePresets: [Preset] { Preset.builtIn + customPresets }

    var isBatch: Bool { videos.count > 1 }

    init(videos: [PickedVideo], onDone: @escaping () -> Void) {
        self.videos = videos
        self.onDone = onDone
        _probes = State(initialValue: Array(repeating: nil, count: videos.count))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isBatch {
                        batchCard
                    } else {
                        sourceCard
                    }

                    if isBatch {
                        if analysisDone {
                            batchList
                        } else {
                            HStack {
                                ProgressView()
                                Text("Analysing \(videos.count) videos…")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    } else if let probe = singleProbe {
                        probeGrid(probe)
                    } else {
                        HStack {
                            ProgressView()
                            Text("Analysing source…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }

                    presetSection

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }

                    startButton
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isBatch ? "Batch · \(videos.count) videos" : "New compression")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New preset…") { showEditor = true }
                }
            }
            .sheet(isPresented: $showEditor) {
                PresetEditorView { newPreset in
                    savePreset(newPreset)
                }
            }
            .sheet(item: $editingPreset) { preset in
                PresetEditorView(existing: preset) { updated in
                    savePreset(updated)
                }
            }
            .task {
                await analyze()
            }
        }
    }

    // MARK: subviews

    /// Batch header: count + total input size.
    private var batchCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(videos.count) videos selected")
                    .font(.callout.weight(.semibold))
                Text("Total input: \(ByteCountFormatter.string(fromByteCount: totalInBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var totalInBytes: Int64 {
        probes.reduce(Int64(0)) { $0 + ($1?.fileSize ?? 0) }
    }

    /// The single source's probe (nil for batches or while analysing).
    private var singleProbe: ProbeResult? { probes.first ?? nil }

    /// Per-video rows for a batch: thumbnail, name, size, duration.
    private var batchList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Videos").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(videos.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    if let thumb = videos[i].thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    } else {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.quaternary)
                            .frame(width: 64, height: 40)
                            .overlay { Image(systemName: "film").font(.caption).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(videos[i].url.lastPathComponent)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(ByteCountFormatter.string(fromByteCount: probes[i]?.fileSize ?? 0, countStyle: .file))
                            if let p = probes[i] {
                                Text("·")
                                Text(String(format: "%d:%02d", Int(p.duration) / 60, Int(p.duration) % 60))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if probes[i] != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if analysisDone {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var sourceCard: some View {
        HStack(spacing: 12) {
            if let thumbnail = videos.first?.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 120, height: 74)
                    .overlay {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(videos.first?.url.lastPathComponent ?? "")
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: singleProbe?.fileSize ?? 0, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let probe = singleProbe, probe.tags.isHDR {
                    Label("HDR source — color-safe pass", systemImage: "sparkles")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.teal.opacity(0.18), in: Capsule())
                        .foregroundStyle(.teal)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func probeGrid(_ probe: ProbeResult) -> some View {
        let cols = [GridItem(.adaptive(minimum: 150), spacing: 10)]
        let cells: [(String, String, String)] = [
            ("Duration", String(format: "%d:%02d", Int(probe.duration) / 60, Int(probe.duration) % 60), "clock"),
            ("Resolution", "\(Int(probe.sourceSize.width))×\(Int(probe.sourceSize.height))", "aspect.ratio"),
            ("Frame rate", String(format: "%.0f fps", probe.nominalFPS), "speedometer"),
            ("Codec", probe.codecSubType, "cpu"),
            ("Audio", probe.hasAudio ? "✓ present" : "none", "waveform"),
            ("Color", probe.tags.humanLabel, "paintpalette"),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Source").font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(cells, id: \.0) { cell in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(cell.0, systemImage: cell.2)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(cell.1)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preset").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("detailed · output size · bitrate")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(availablePresets, id: \.id) { preset in
                PresetRow(preset: preset,
                          isSelected: selectedPreset?.id == preset.id,
                          probe: singleProbe,
                          batchTotalBytes: isBatch ? totalBatchOutBytes(for: preset) : nil) {
                    selectedPreset = preset
                }
                .contextMenu {
                    if preset.isUserDefined {
                        Button {
                            editingPreset = preset
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button {
                            duplicatePreset(preset)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deletePreset(preset)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } else {
                        Button {
                            duplicatePreset(preset)
                        } label: {
                            Label("Duplicate as custom", systemImage: "plus.square.on.square")
                        }
                    }
                }
            }
        }
    }

    // Estimate card (live) + start button

    /// Total ESTIMATED OUTPUT for the whole batch with a given preset.
    private func totalBatchOutBytes(for preset: Preset) -> Int64? {
        guard analysisDone else { return nil }
        var valid = 0
        var total: Int64 = 0
        for p in probes where p != nil {
            total += Int64(QualitySizeOptimizer.plan(preset: preset, probe: p!).estimatedSizeMB() * 1_048_576)
            valid += 1
        }
        return valid > 0 ? total : nil
    }

    private var estimate: OptimizerPlan? {
        guard let probe = singleProbe, let preset = selectedPreset else { return nil }
        return QualitySizeOptimizer.plan(preset: preset, probe: probe)
    }

    private var startButton: some View {
        VStack(spacing: 8) {
            if isBatch {
                if let total = totalBatchOutBytes(for: selectedPreset ?? Preset.builtIn[0]) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Estimated output (all \(videos.count) videos)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "≈ %.0f MB total", Double(total) / 1_048_576))
                                .font(.title3.weight(.bold).monospacedDigit())
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Bitrate (per video)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f + %.0f kbps",
                                        Double(estimate?.videoBitrate ?? 0) / 1_000_000,
                                        Double(estimate?.audioBitrate ?? 0) / 1000))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14))

                    Text("One preset applied to every video · each row shows its own estimate · jobs run one at a time in the queue")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let est = estimate {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Estimated output")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "≈ %.0f MB", est.estimatedSizeMB()))
                            .font(.title3.weight(.bold).monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Bitrate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f + %.0f kbps",
                                    Double(est.videoBitrate) / 1_000_000,
                                    Double(est.audioBitrate) / 1000))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14))

                Text(est.rationale)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                start()
            } label: {
                HStack {
                    if !analysisDone {
                        ProgressView().tint(.white)
                    }
                    Image(systemName: isBatch ? "square.stack.3d.up.badge.plus" : "arrow.down.forward.circle.fill")
                    Text(buttonTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
        }
    }

    private var buttonTitle: String {
        if !analysisDone { return "Analysing…" }
        guard selectedPreset != nil else { return "Choose a preset" }
        return isBatch ? "Compress \(videos.count) videos" : "Compress"
    }

    private var canStart: Bool {
        guard analysisDone, selectedPreset != nil else { return false }
        return probes.contains { $0 != nil }
    }

    private func start() {
        guard let preset = selectedPreset, analysisDone else { return }
        for i in videos.indices {
            guard let probe = probes[i] else { continue }
            let plan = QualitySizeOptimizer.plan(preset: preset, probe: probe)
            coordinator.enqueue(source: videos[i].url, probe: probe, plan: plan,
                                preset: preset, thumbnail: videos[i].thumbnail)
        }
        onDone()
    }

    // MARK: preset management

    /// Insert-or-replace by id: edits update in place, new presets append.
    private func savePreset(_ preset: Preset) {
        if let idx = customPresets.firstIndex(where: { $0.id == preset.id }) {
            customPresets[idx] = preset
        } else {
            customPresets.append(preset)
        }
        PresetStore.saveCustom(customPresets)
        selectedPreset = preset
        PresetStore.setLastUsedPreset(preset.id)
    }

    /// Copy a preset (built-in or custom) as a new user-defined one.
    private func duplicatePreset(_ preset: Preset) {
        var copy = preset
        copy.id = UUID()
        copy.isUserDefined = true
        copy.name = preset.name + " (custom)"
        savePreset(copy)
    }

    private func deletePreset(_ preset: Preset) {
        customPresets.removeAll { $0.id == preset.id }
        PresetStore.saveCustom(customPresets)
        if selectedPreset?.id == preset.id {
            selectedPreset = Preset.builtIn[0]
            PresetStore.setLastUsedPreset(selectedPreset!.id)
        }
    }

    // MARK: analysis

    private func analyze() async {
        selectedPreset = {
            let last = PresetStore.lastUsedPresetID()
            return availablePresets.first { $0.id == last } ?? Preset.builtIn[0]
        }()
        var failures = 0
        for i in videos.indices {
            do {
                let p = try await ProbeResult.probe(url: videos[i].url)
                if p.duration.isNaN || p.duration <= 0 {
                    failures += 1
                    continue
                }
                probes[i] = p
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            errorText = failures == videos.count
                ? "None of the selected files could be analysed; they may be unsupported."
                : "\(failures) of \(videos.count) videos couldn't be analysed and will be skipped."
        }
        analysisDone = true
        if let id = selectedPreset?.id {
            PresetStore.setLastUsedPreset(id)
        }
    }
}

/// A selectable detailed preset row: name, codec, resolution, bitrate and
/// a live estimated file size for the current source (or the batch total).
private struct PresetRow: View {
    let preset: Preset
    let isSelected: Bool
    let probe: ProbeResult?
    var batchTotalBytes: Int64?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        TagChip(text: preset.codec == .hevc ? "HEVC" : "H.264")
                        TagChip(text: preset.resolution.rawValue)
                        // Bitrate intentionally NOT a chip: it's shown at the
                        // trailing side (and in the estimate card) — a second
                        // dark pill here just cluttered the row.
                    }
                }
                Spacer()
                if let probe {
                    let plan = QualitySizeOptimizer.plan(preset: preset, probe: probe)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "≈ %.0f MB", plan.estimatedSizeMB()))
                            .font(.callout.weight(.bold).monospacedDigit())
                            .foregroundStyle(.tint)
                        Text(String(format: "%.1f Mbps", Double(plan.videoBitrate) / 1e6))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let totalBytes = batchTotalBytes {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "≈ %.0f MB total", Double(totalBytes) / 1_048_576))
                            .font(.callout.weight(.bold).monospacedDigit())
                            .foregroundStyle(.tint)
                        Text(String(format: "%.1f Mbps", Double(preset.fixedBitrateMbps)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(isSelected ? Color.blue.opacity(0.08) : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct TagChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .foregroundStyle(.secondary)
    }
}
