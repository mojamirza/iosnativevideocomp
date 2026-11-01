import SwiftUI
import AVFoundation

/// Persists user-defined presets in UserDefaults.
enum PresetStore {
    /// v2 storage key: the preset system changed to fixed-bitrate-only, and
    /// presets saved by older versions (adaptive/size-target modes) cannot be
    /// represented faithfully — they decoded to misleading default bitrates.
    /// Reading a fresh key drops those stale entries once, cleanly.
    private static let customsKey = "customPresets.v2"

    static func loadCustom() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: customsKey) else { return [] }
        // LENIENT decode: presets round-trip as a JSON array, and a plain
        // [Preset] decode is all-or-nothing — one bad element (hand-edited,
        // corrupted, or from a very old schema) would silently lose ALL
        // customs. Decode each element independently and skip failures.
        guard let dicts = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        var out: [Preset] = []
        for dict in dicts {
            guard let d = try? JSONSerialization.data(withJSONObject: dict),
                  let p = try? JSONDecoder().decode(Preset.self, from: d) else { continue }
            out.append(p)
        }
        return out
    }

    static func saveCustom(_ presets: [Preset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: customsKey)
        }
    }

    static func lastUsedPresetID() -> UUID? {
        guard let s = UserDefaults.standard.string(forKey: "lastPresetID") else { return nil }
        return UUID(uuidString: s)
    }

    static func setLastUsedPreset(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: "lastPresetID")
    }
}

/// Editor for a custom preset: codec, resolution class, exact bitrate
/// (slider + typeable field), fps cap, audio bitrate.
/// Pass `existing:` to edit (or duplicate) a preset instead of creating one.
struct PresetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let existing: Preset?
    /// The video currently being set up (nil elsewhere): powers the live
    /// estimate, the quality hint and the "fit under X MB" helper.
    let contextProbe: ProbeResult?
    let onSaved: (Preset) -> Void

    @State private var name: String
    @State private var codec: VideoCodec
    @State private var resolution: ResolutionClass
    @State private var fixedMbps: Double
    @State private var bitrateText: String
    @State private var fitUnderText: String = ""
    @State private var fpsCapEnabled: Bool
    @State private var fpsCap: Double
    @State private var audioKbps: Double
    /// LOG slider position 0…1: 0.1 Mbps → 40 Mbps on a log scale — useful
    /// values cluster between 1 and 10, where a linear bar starved the arm.
    @State private var sliderPos: Double

    init(existing: Preset? = nil, contextProbe: ProbeResult? = nil, onSaved: @escaping (Preset) -> Void) {
        self.existing = existing
        self.contextProbe = contextProbe
        self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "Custom")
        _codec = State(initialValue: existing?.codec ?? .hevc)
        _resolution = State(initialValue: existing?.resolution ?? .keep)
        let mbps = existing?.fixedBitrateMbps ?? 4
        _fixedMbps = State(initialValue: mbps)
        _bitrateText = State(initialValue: String(format: "%.1f", mbps))
        _sliderPos = State(initialValue: Self.pos(fromMbps: mbps))
        _fpsCapEnabled = State(initialValue: existing?.fpsCap != nil)
        _fpsCap = State(initialValue: Double(existing?.fpsCap ?? 30))
        _audioKbps = State(initialValue: Double(existing?.audioBitrateKbps ?? 128))
    }

    private static func pos(fromMbps m: Double) -> Double {
        let v = min(40, max(0.1, m))
        return log(v / 0.1) / log(400)          // 0.1 → 0.0, 40 → 1.0
    }

    private static func mbps(fromPos t: Double) -> Double {
        0.1 * pow(400, min(1, max(0, t)))
    }

    /// Plain-language quality rating from bits-per-pixel-second against the
    /// probed resolution + frame rate. bpp ≈ bitrate/(W·H·fps); the ranges
    /// come from common HEVC experience (0.06 ≈ 4 Mbps 1080p30).
    private func qualityHint() -> (label: String, color: Color)? {
        guard let probe = contextProbe else { return nil }
        let w = max(1, Double(probe.sourceSize.width))
        let h = max(1, Double(probe.sourceSize.height))
        let fps = max(1, Double(probe.nominalFPS))
        let bpp = fixedMbps * 1_000_000 / (w * h * fps)
        let res = "\(Int(probe.sourceSize.width))×\(Int(probe.sourceSize.height))"
        switch bpp {
        case ..<0.045:
            return ("Low for \(res) — expect blockiness on busy motion",
                    Color(UIColor.systemOrange))
        case ..<0.20:
            return ("Good for \(res) — a sensible bitrate", .green)
        default:
            return ("High for \(res) — most bits exceed what the pixels can use",
                    Color(UIColor.systemTeal))
        }
    }

    /// Estimated output size for the draft preset against the given source.
    private func draftEstimateBytes(for probe: ProbeResult) -> Int64 {
        let draft = Preset(
            name: name.isEmpty ? "Custom" : name,
            codec: codec,
            resolution: resolution,
            fixedBitrateMbps: fixedMbps,
            fpsCap: fpsCapEnabled ? Int(fpsCap) : nil,
            audioBitrateKbps: Int(audioKbps),
            isUserDefined: true)
        let est = QualitySizeOptimizer.plan(preset: draft, probe: probe)
        return Int64(est.estimatedSizeMB() * 1_048_576)
    }

    /// "Fit under X MB": exact video bitrate that keeps video + audio (at the
    /// current audio setting, over the source duration) under the target.
    private func applyFit() {
        guard let probe = contextProbe, probe.duration > 0.5,
              let mb = Double(fitUnderText.replacingOccurrences(of: ",", with: ".")),
              mb >= 1, mb <= 200_000 else { return }
        let totalMbits = mb * 8
        let audioMbits = Double(audioKbps) * probe.duration / 1000
        let videoMBits = max(1, totalMbits - audioMbits)
        let videoMbps = videoMBits / probe.duration
        let clamped = min(40, max(0.1, videoMbps))
        fixedMbps = clamped
        bitrateText = String(format: "%.1f", clamped)
        sliderPos = Self.pos(fromMbps: clamped)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name & codec") {
                    TextField("Preset name", text: $name)
                    Picker("Codec", selection: $codec) {
                        ForEach(VideoCodec.allCases) { c in Text(c.displayName).tag(c) }
                    }
                    Picker("Resolution", selection: $resolution) {
                        ForEach(ResolutionClass.allCases) { r in Text(r.displayName).tag(r) }
                    }
                }

                // TARGET SIZE — its own section ABOVE the bitrate. The Fit
                // helper never crowds the slider row, and the semantics are
                // stated up front: type a size goal, Fit solves the bitrate.
                Section("Target size (optional)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Know the file size you need — messaging or attachment limits? Type it in MB and tap Fit: the bitrate below is solved so video + audio land under that size. The output stays a fixed bitrate — re-tap Fit after changing resolution or audio.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            TextField("Target size", text: $fitUnderText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .font(.body.monospacedDigit())
                            Text("MB")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                applyFit()
                            } label: {
                                // No icon: the artwork vanished from the filled
                                // (blue) state on device — a plain bold label
                                // reads cleaner anyway.
                                Text("Fit bitrate")
                                    .font(.headline)
                                    .padding(.vertical, 2)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(fitUnderText.isEmpty)
                        }
                    }
                }

                Section("Video bitrate") {
                    VStack(alignment: .leading, spacing: 9) {
                        // SLIDER + TAP-TO-EDIT number: the field IS the readout
                        // beside the bar. Tap the number, type an exact value,
                        // and the slider follows. No separate field row.
                        HStack {
                            // LOGARITHMIC slider — useful values cluster
                            // between 1 and 10 Mbps, where a linear bar
                            // starved the low end.
                            Slider(value: $sliderPos, in: 0...1, step: 0.005)
                                .onChange(of: sliderPos) { _, t in
                                    let mbps = Self.mbps(fromPos: t)
                                    // Only rewrite the text field when the
                                    // change came from the slider — never
                                    // clobber what the user is typing.
                                    let typed = Double(bitrateText.replacingOccurrences(of: ",", with: ".")) ?? -1
                                    if abs(typed - mbps) > 0.05 {
                                        bitrateText = String(format: "%.1f", mbps)
                                    }
                                    fixedMbps = mbps
                                }
                            TextField("0", text: $bitrateText)
                                .keyboardType(.decimalPad)
                                // Centered so the digits sit right on the
                                // underline regardless of value length.
                                .multilineTextAlignment(.center)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .textFieldStyle(.plain)
                                // Grows with what is typed; at minimum a
                                // tappable sliver.
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 40)
                                .padding(.bottom, 3)
                                // Short underline: tap-to-edit affordance.
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Color(.separator))
                                        .frame(height: 1)
                                }
                                .onChange(of: bitrateText) { _, t in
                                    if let v = Double(t.replacingOccurrences(of: ",", with: ".")),
                                       v >= 0.1, v <= 40 {
                                        fixedMbps = v
                                        sliderPos = Self.pos(fromMbps: v)
                                    }
                                }
                            Text("Mbps")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        // QUALITY hint: rate the chosen bitrate against the
                        // source resolution + fps BEFORE committing.
                        if let hint = qualityHint() {
                            Label(hint.label, systemImage: "gauge.with.needle")
                                .font(.footnote)
                                .foregroundStyle(hint.color)
                        }
                        // LIVE estimate for the video being set up — tuning
                        // a preset is never guesswork.
                        if let probe = contextProbe {
                            let outBytes = draftEstimateBytes(for: probe)
                            let pct = probe.fileSize > 0
                                ? (1 - Double(outBytes) / Double(probe.fileSize)) * 100 : 0
                            Text(String(format: "%@ → ≈ %@ (−%.0f%%)",
                                        ByteCountFormatter.string(fromByteCount: probe.fileSize, countStyle: .file),
                                        ByteCountFormatter.string(fromByteCount: outBytes, countStyle: .file),
                                        max(0, pct)))
                                .font(.footnote.weight(.medium).monospacedDigit())
                                .foregroundStyle(.tint)
                        }
                        Text("Drag the bar or tap the number next to it to type an exact value. Lower = smaller file.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Frame rate") {
                    Toggle("Cap frame rate", isOn: $fpsCapEnabled)
                    if fpsCapEnabled {
                        HStack {
                            Slider(value: $fpsCap, in: 10...60, step: 1)
                            Text("\(Int(fpsCap)) fps")
                                .font(.callout.monospacedDigit())
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                }

                Section("Audio") {
                    HStack {
                        Slider(value: $audioKbps, in: 32...320, step: 16)
                        Text("\(Int(audioKbps)) kbps")
                            .font(.callout.monospacedDigit())
                            .frame(width: 90, alignment: .trailing)
                    }
                    Text("AAC is encoded by AVFoundation at this budget. Tracks are kept when present.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "Custom preset" : "Edit preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        var preset = Preset(
                            name: name.isEmpty ? "Custom" : name,
                            codec: codec,
                            resolution: resolution,
                            fixedBitrateMbps: fixedMbps,
                            fpsCap: fpsCapEnabled ? Int(fpsCap) : nil,
                            audioBitrateKbps: Int(audioKbps),
                            isUserDefined: true
                        )
                        // Editing preserves the preset's identity so the stored
                        // copy is replaced in place.
                        preset.id = existing?.id ?? preset.id
                        onSaved(preset)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
