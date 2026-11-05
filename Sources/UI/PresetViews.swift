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
    /// Strategic question the user answers FIRST: "cap the bitrate" or
    /// "guarantee a target size". Replaces the old Fit button — target size
    /// is a MODE, not an afterthought that silently disarms on edits.
    private enum RateMode: String, CaseIterable, Identifiable {
        case bitrate = "Bitrate", target = "Target size"
        var id: String { rawValue }
    }
    @State private var rateMode: RateMode
    /// Forced mono voice track (lecture mode recipe).
    @State private var monoAudio: Bool
    /// REAL HDR→SDR conversion (opt-in). Only offered/shown when the video
    /// currently being set up IS HDR — otherwise SDR-to-SDR "conversion"
    /// would be a no-op hiding behind a toggle.
    @State private var hdrConvert: Bool
    @State private var fpsCapEnabled: Bool
    @State private var fpsCap: Double
    @State private var audioKbps: Double
    /// LOG slider position 0…1: 0.1 Mbps → 40 Mbps on a log scale — useful
    /// values cluster between 1 and 10, where a linear bar starved the arm.
    @State private var sliderPos: Double

    /// Field focus: the number pads have NO return/done key, so dismissing
    /// the keyboard needs an explicit control (Fit / the keyboard's Done key).
    /// Without this, the keyboard swallowed the FIRST tap on Fit.
    @FocusState private var fitMBFocused: Bool
    @FocusState private var bitrateFocused: Bool

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
        _rateMode = State(initialValue: existing?.targetSizeMB != nil ? .target : .bitrate)
        _monoAudio = State(initialValue: existing?.audioChannels == 1)
        _hdrConvert = State(initialValue: existing?.hdrToSDR == true)
        _fitUnderText = State(initialValue: existing?.targetSizeMB
            .map { $0 == $0.rounded() ? "\(Int($0))" : String(format: "%.1f", $0) } ?? "")
    }

    private static func pos(fromMbps m: Double) -> Double {
        let lo = Preset.bitrateRange.lowerBound
        let hi = Preset.bitrateRange.upperBound
        let v = min(hi, max(lo, m))
        return log(v / lo) / log(hi / lo)      // floor → 0.0, ceiling → 1.0
    }

    private static func mbps(fromPos t: Double) -> Double {
        let lo = Preset.bitrateRange.lowerBound
        let hi = Preset.bitrateRange.upperBound
        return lo * pow(hi / lo, min(1, max(0, t)))
    }

    /// Plain-language quality rating from bits-per-pixel-second. Rates the
    /// PLANNED OUTPUT resolution/fps — rating the source's pixels told the
    /// user "Good for 3840×2160" while the preset was compressing to 1080p.
    /// bpp ≈ bitrate/(W·H·fps); the ranges come from common HEVC experience
    /// (0.06 ≈ 4 Mbps 1080p30).
    private func qualityHint() -> (label: String, color: Color)? {
        guard let probe = contextProbe else { return nil }
        let out = resolution.outputSize(for: probe.sourceSize)
        let w = max(1, Double(out.width))
        let h = max(1, Double(out.height))
        var fps = probe.nominalFPS > 0 ? Double(probe.nominalFPS) : 30.0
        if fpsCapEnabled { fps = min(fps, Double(fpsCap)) }
        let bpp = fixedMbps * 1_000_000 / (w * h * max(1, fps))
        let res = "\(Int(out.width))×\(Int(out.height))"
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

    /// The plan the CURRENT draft state would produce — the one and only
    /// estimator used everywhere: the number on screen is the number the
    /// job will run with (same plan() call the coordinator makes).
    private func draftPlan(for probe: ProbeResult) -> OptimizerPlan {
        QualitySizeOptimizer.plan(preset: Preset(
            name: name,
            codec: codec,
            resolution: resolution,
            fixedBitrateMbps: fixedMbps,
            fpsCap: fpsCapEnabled ? Int(fpsCap) : nil,
            audioBitrateKbps: Int(audioKbps),
            isUserDefined: true,
            targetSizeMB: rateMode == .target ? targetMB : nil,
            audioChannels: monoAudio ? 1 : nil,
            hdrToSDR: hdrConvert ? true : nil), probe: probe)
    }

    /// Parsed, range-checked target (MB) from the text field. The PRESET
    /// model clamps to 1…2 000 MB — the UI validates the same range so a
    /// saved preset never differs from what was typed. Persian/Arabic
    /// digits and "٫"/"," survive Double() only through normalisedDecimal.
    private var targetMB: Double? {
        guard let v = Double(normalizedDecimal(fitUnderText)),
              v >= 1, v <= 2_000 else { return nil }
        return v
    }

    /// Decimal normaliser for typed numbers: folds Latin, Eastern-Arabic and
    /// Persian-Indic digits to ASCII and "٫"/"," to "." so Double() cannot
    /// silently fail on an international keyboard.
    private func normalizedDecimal(_ s: String) -> String {
        var out = ""
        for ch in s {
            if let d = ch.wholeNumberValue { out.append(String(d)) }
            else if ",٫.".contains(ch) { out.append(".") }
        }
        return out
    }

    /// The readout beside the slider is the field: while the text is not a
    /// usable bitrate (cleared, mistyped, out of 0.1…40), `fixedMbps` still
    /// holds the last good value — the UI must SAY so and Save must refuse,
    /// otherwise an invalid edit silently saves the old number.
    private var bitrateIsValid: Bool {
        guard let v = Double(normalizedDecimal(bitrateText)) else { return false }
        return v >= Preset.bitrateRange.lowerBound && v <= Preset.bitrateRange.upperBound
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

                // RATE CONTROL — the strategic question now comes FIRST:
                // "cap the bitrate" or "guarantee a target size". Target size
                // is a MODE, not a Fit button that silently disarms on edits.
                // ONE draftPlan() (the same plan() the coordinator runs)
                // powers every number beneath — editor, preset rows and the
                // estimate bar can never disagree again.
                Section("Rate control") {
                    Picker("Rate control", selection: $rateMode) {
                        ForEach(RateMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if rateMode == .bitrate {
                        // ---- BITRATE MODE: slider + exact typed value ----
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
                                        let typed = Double(normalizedDecimal(bitrateText)) ?? -1
                                        if abs(typed - mbps) > 0.05 {
                                            bitrateText = String(format: "%.1f", mbps)
                                        }
                                        fixedMbps = mbps
                                    }
                                TextField("0", text: $bitrateText)
                                    .focused($bitrateFocused)
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
                                        if let v = Double(normalizedDecimal(t)),
                                           v >= Preset.bitrateRange.lowerBound,
                                           v <= Preset.bitrateRange.upperBound {
                                            fixedMbps = v
                                            sliderPos = Self.pos(fromMbps: v)
                                        }
                                    }
                                Text("Mbps")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            // Invalid edit feedback: while the text can't parse
                            // (or is out of range), the readout shows nothing but
                            // the LAST good value still drives Save — say so here.
                            if !bitrateIsValid {
                                Text("Out of range (0.15–40) — still using \(String(format: "%.2f", fixedMbps)) Mbps. Save is disabled while the value is invalid.")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                            // QUALITY hint: rate the chosen bitrate against the
                            // PLANNED OUTPUT resolution + fps BEFORE committing.
                            if let hint = qualityHint() {
                                Label(hint.label, systemImage: "gauge.with.needle")
                                    .font(.footnote)
                                    .foregroundStyle(hint.color)
                            }
                            // LIVE estimate + CAP explanation for the video
                            // being set up — tuning a preset is never
                            // guesswork. Same plan() the job will run.
                            if let probe = contextProbe {
                                let plan = draftPlan(for: probe)
                                let outBytes = plan.estimatedBytes
                                let pct = probe.fileSize > 0
                                    ? (1 - Double(outBytes) / Double(probe.fileSize)) * 100 : 0
                                Text(String(format: "%@ → ≈ %@ (−%.0f%%)",
                                            ByteCountFormatter.string(fromByteCount: probe.fileSize, countStyle: .file),
                                            ByteCountFormatter.string(fromByteCount: outBytes, countStyle: .file),
                                            max(0, pct)))
                                    .font(.footnote.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.tint)
                                if plan.bitrateCapped,
                                   probe.videoDataRate > 0, probe.videoDataRate.isFinite {
                                    // Int(Double) traps on non-finite — the
                                    // min() keeps even absurd rates in range.
                                    let srcMbps = SizeMath.mbpsLabel(
                                        Int(min(probe.videoDataRate, 1e9)))
                                    Label("Using \(SizeMath.mbpsLabel(plan.videoBitrate)) Mbps — the source only contains about \(srcMbps) Mbps, so more bits would only grow the file.",
                                          systemImage: "gauge.with.dots.needle.bottom.50percent")
                                        .font(.footnote)
                                        .foregroundStyle(Color(UIColor.systemOrange))
                                }
                            }
                            Text("Drag the bar or tap the number next to it to type an exact value. Lower = smaller file.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // ---- TARGET MODE: solved from the budget, not typed ----
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Type the size you need: the bitrate is SOLVED to land the whole file under it — container overhead included — and the encode re-checks its real bytes, re-encoding up to twice if a pass drifts over.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                TextField("Target size", text: $fitUnderText)
                                    .focused($fitMBFocused)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .font(.body.monospacedDigit())
                                Text("MB")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            if let probe = contextProbe {
                                let plan = draftPlan(for: probe)
                                if !plan.targetFeasible {
                                    Text("Too small for this video's length.")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.red)
                                } else if let t = targetMB {
                                    Text("≈ \(SizeMath.mbpsLabel(plan.videoBitrate)) Mbps solved for this video · expected ≈ \(ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file)) (≤ \(t == t.rounded() ? "\(Int(t))" : String(format: "%.1f", t)) MB)")
                                        .font(.footnote.weight(.medium).monospacedDigit())
                                        .foregroundStyle(.tint)
                                }
                            } else {
                                Text("The target is saved with the preset; each video's bitrate is solved from its own length when the encode starts.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if targetMB == nil, !fitUnderText.isEmpty {
                                Text("Enter a target between 1 and 2000 MB.")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
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
                    // Forced mono: the lecture/screen-recording recipe. The
                    // engine caps the encode so the budget's audio share
                    // can't be broken (the encode never EXCEEDS the planned
                    // audio rate).
                    Toggle("Mono voice track", isOn: $monoAudio)
                    Text("AAC is encoded by AVFoundation at this budget. Tracks are kept when present.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // REAL HDR → SDR, offered ONLY on an HDR source. This is a
                // deliberate conversion (BT.2100 tone-map → 709 re-encode,
                // verified in the report) — never a relabeling. Off = keep
                // HDR untouched (the default, 10-bit Main10 HEVC).
                if contextProbe?.tags.isHDR == true {
                    Section("HDR output") {
                        Picker("Color space", selection: $hdrConvert) {
                            Text("Keep HDR").tag(false)
                            Text("Convert to SDR").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if hdrConvert {
                            Text("Tone-maps the video into standard dynamic range (Rec.709, 8-bit) so it looks right on any older display. Highlights above SDR white clip — typical for every SDR conversion. Report shows: \"SDR conversion verified\".")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Output stays \(contextProbe?.tags.humanLabel ?? "HDR"): fewer devices can show its true colors, but nothing is altered.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Custom preset" : "Edit preset")
            .navigationBarTitleDisplayMode(.inline)
            // Any scroll (e.g. to the Save… row area) instantly drops the
            // number pads — they linger otherwise and eat taps below.
            .scrollDismissesKeyboard(.immediately)
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
                            isUserDefined: true,
                            // Target MODE saves the guaranteed budget as a
                            // first-class property of the preset (per-video
                            // solve + measured re-encode + verified report
                            // — never a hand-solved slider value).
                            targetSizeMB: rateMode == .target ? targetMB : nil,
                            audioChannels: monoAudio ? 1 : nil,
                            // Only a positive flag is persisted; nil means
                            // "keep HDR" — a preset saved on an HDR video
                            // must not silently convert HDR videos later.
                            hdrToSDR: hdrConvert ? true : nil
                        )
                        // Editing preserves the preset's identity so the stored
                        // copy is replaced in place.
                        preset.id = existing?.id ?? preset.id
                        onSaved(preset)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    // Bitrate mode: an invalid typed bitrate (cleared or out
                    // of range) refuses to save. Target mode: an invalid
                    // target refuses instead — the typed bitrate is stored
                    // but never drives the encode.
                    .disabled(rateMode == .target ? targetMB == nil : !bitrateIsValid)
                }
                // Keyboard accessory: the number pads have no return key, so
                // there was no way to dismiss the keyboard except tapping —
                // and that first tap was swallowed by the dismissal. Done
                // gives an explicit exit that costs no button tap.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        fitMBFocused = false
                        bitrateFocused = false
                    }
                }
            }
        }
    }
}
