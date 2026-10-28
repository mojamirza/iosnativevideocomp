import SwiftUI
import AVFoundation

/// Shown right after picking a video: probe summary, preset selection with a
/// live *estimated output size / bitrate*, and the Compress button.
struct SetupFlowView: View {
    @EnvironmentObject private var coordinator: JobCoordinator

    let sourceURL: URL
    let thumbnail: UIImage?
    let onDone: () -> Void

    @State private var probe: ProbeResult?
    @State private var complexity: ComplexityScore?
    @State private var analysisFailed = false
    @State private var selectedPreset: Preset?
    @State private var errorText: String?
    @State private var customPresets: [Preset] = PresetStore.loadCustom()
    @State private var showEditor = false

    var availablePresets: [Preset] { Preset.builtIn + customPresets }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceCard

                    if let probe {
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

                    if selectedPreset?.fixedBitrateMbps == nil,
                       selectedPreset?.sizeTargetMB == nil,
                       let complexity {
                        Label {
                            Text(complexity.value >= 0.66
                                 ? "Highly detailed footage — the optimizer will allocate more bitrate."
                                 : complexity.value <= 0.28
                                 ? "Static, low-detail footage — expect excellent compression."
                                 : "Moderate detail — optimizer chose a balanced bitrate.")
                        } icon: {
                            Image(systemName: "wand.and.stars")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

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
            .navigationTitle("New compression")
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
                    customPresets.append(newPreset)
                    PresetStore.saveCustom(customPresets)
                    selectedPreset = newPreset
                }
            }
            .task {
                await analyze()
            }
        }
    }

    // MARK: subviews

    private var sourceCard: some View {
        HStack(spacing: 12) {
            if let thumbnail {
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
                Text(sourceURL.lastPathComponent)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: probe?.fileSize ?? 0, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let probe, probe.tags.isHDR {
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

            ForEach(Array(availablePresets.enumerated()), id: \.element.id) { index, preset in
                PresetRow(preset: preset,
                          isSelected: selectedPreset?.id == preset.id,
                          probe: probe,
                          complexity: complexity,
                          accent: index == 0 && !preset.isUserDefined) {
                    selectedPreset = preset
                }
            }
        }
    }

    // Estimate card (live) + start button
    private var estimate: OptimizerPlan? {
        guard let probe, let complexity, let preset = selectedPreset else { return nil }
        return QualitySizeOptimizer.plan(preset: preset, probe: probe, complexity: complexity)
    }

    private var startButton: some View {
        VStack(spacing: 8) {
            if let est = estimate {
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
                    if probe == nil {
                        ProgressView().tint(.white)
                    }
                    Image(systemName: "arrow.down.forward.circle.fill")
                    Text(selectedPreset == nil ? "Choose a preset" : "Compress")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(probe == nil || selectedPreset == nil)
        }
    }

    private func start() {
        guard let preset = selectedPreset,
              let probe = probe,
              let complexity = complexity else { return }
        let plan = QualitySizeOptimizer.plan(preset: preset, probe: probe, complexity: complexity)
        coordinator.enqueue(source: sourceURL, probe: probe, plan: plan,
                            preset: preset, thumbnail: thumbnail)
        onDone()
    }

    // MARK: analysis

    private func analyze() async {
        selectedPreset = {
            let last = PresetStore.lastUsedPresetID()
            return availablePresets.first { $0.id == last } ?? Preset.builtIn[0]
        }()
        do {
            let p = try await ProbeResult.probe(url: sourceURL)
            if p.duration.isNaN || p.duration <= 0 {
                errorText = "Could not read a valid duration; this file may be unsupported."
                return
            }
            probe = p
            do {
                complexity = try await ComplexityAnalyzer.analyze(url: sourceURL, probe: p)
            } catch {
                analysisFailed = true
            }
        } catch {
            errorText = error.localizedDescription
        }
        if analysisFailed {
            // Optimizer still works: complexity defaults to "balanced".
            complexity = ComplexityScore(value: 0.5, spatialDetail: 0, motion: 0, sampledFrames: 0)
        }
        if let id = selectedPreset?.id {
            PresetStore.setLastUsedPreset(id)
        }
    }
}

/// A selectable detailed preset row: name, codec, resolution, bitrate mode and
/// a live estimated file size for the current source.
private struct PresetRow: View {
    let preset: Preset
    let isSelected: Bool
    let probe: ProbeResult?
    let complexity: ComplexityScore?
    let accent: Bool
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
                        TagChip(text: preset.modeSummary)
                    }
                }
                Spacer()
                if let probe, let complexity {
                    let plan = QualitySizeOptimizer.plan(preset: preset, probe: probe, complexity: complexity)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "≈ %.0f MB", plan.estimatedSizeMB()))
                            .font(.callout.weight(.bold).monospacedDigit())
                            .foregroundStyle(.tint)
                        Text(String(format: "%.1f Mbps", Double(plan.videoBitrate) / 1e6))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if accent {
                    Text("ADAPTIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.teal)
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
