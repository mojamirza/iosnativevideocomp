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
    /// Inline feedback for Fit failures (bad target, too small for the
    /// duration): the prominent button must never do nothing silently.
    @State private var fitMessage: String?
    /// GUARANTEED target: set ONLY by tapping Fit — the encode then measures
    /// itself against that budget and re-encodes once if it drifts over.
    /// Manual bitrate edits CLEAR it (an arbitrary manual bitrate would push
    /// the file past the budget and the report would fail the promise).
    @State private var guaranteedTargetMB: Double?
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
        _guaranteedTargetMB = State(initialValue: existing?.targetSizeMB)
        _fitUnderText = State(initialValue: existing?.targetSizeMB
            .map { Int($0) == Int($0) ? "\(Int($0))" : String(format: "%.1f", $0) } ?? "")
    }

    private static func pos(fromMbps m: Double) -> Double {
        let v = min(40, max(0.1, m))
        return log(v / 0.1) / log(400)          // 0.1 → 0.0, 40 → 1.0
    }

    private static func mbps(fromPos t: Double) -> Double {
        0.1 * pow(400, min(1, max(0, t)))
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
        // estimatedBytes does the bit-math once — the old MB × 1_048_576
        // chain inflated the estimate ≈4.9 %.
        return est.estimatedBytes
    }

    /// "Fit under X MB": exact fixed video bitrate that keeps video + audio —
    /// at the current audio setting, over the source duration — under the
    /// TARGET, with two honest corrections: an ~8 % headroom factor because
    /// VideoToolbox's average-bitrate mode overshoots and the container adds
    /// overhead (targeting 100 % of the cap usually produces an OVER-limit
    /// file), and audio that simply doesn't exist is not budgeted. Dismisses
    /// the keyboard FIRST so the tap that lands here can't be eaten by the
    /// responder change. Any failure shows a message — the prominent button
    /// must never silently do nothing.
    private func applyFit() {
        fitMBFocused = false
        bitrateFocused = false
        guard let probe = contextProbe, probe.duration > 0.5,
              let mb = Double(normalizedDecimal(fitUnderText)),
              mb >= 1, mb <= 200_000 else {
            fitMessage = "Enter a target of at least 1 MB."
            return
        }
        // INPUT is normalised digits (+ decimal separators) — Persian/Arabic
        // digits and "٫"/"," survive Double() only through normalisedDecimal.
        let audioMbits = probe.hasAudio ? audioKbps * probe.duration / 1000 : 0
        let videoMbps = (mb * 8 * 0.92 - audioMbits) / probe.duration
        guard videoMbps >= 0.1 else {
            fitMessage = "That target is too small for this video's length."
            return
        }
        fitMessage = nil
        let clamped = min(40, videoMbps)
        fixedMbps = clamped
        bitrateText = String(format: "%.1f", clamped)
        sliderPos = Self.pos(fromMbps: clamped)
        // GUARANTEE: Fit doesn't just aim at the target — the job now carries
        // the budget, and the encode verifies its real bytes against it,
        // re-encoding once if the encoder's overshoot pushed it over.
        guaranteedTargetMB = mb
    }

    /// The GUARANTEE stays alive only while the CURRENT bitrate still equals
    /// the Fit solve for that target. Manual edits (slider, typed values,
    /// or audio/resolution changes) invalidate it — derived, not raced: a
    /// manual overshoot must not silently violate the promised budget.
    private var activeTargetMB: Double? {
        guard let mb = guaranteedTargetMB, let probe = contextProbe else { return nil }
        let audioMbits = probe.hasAudio ? audioKbps * probe.duration / 1000 : 0
        let solved = (mb * 8 * 0.92 - audioMbits) / probe.duration
        let clamped = min(40, solved)
        if clamped >= 0.1, abs(clamped - fixedMbps) < 0.06 { return mb }
        return nil
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
        return v >= 0.1 && v <= 40
    }

    /// One-line status of the armed target guarantee.
    private func activeTargetLabel(_ mb: Double) -> String {
        let whole = mb == mb.rounded()
        let shown = whole ? String(Int(mb)) : String(format: "%.1f", mb)
        return "Guaranteed: this video will come out under \(shown) MB — the encode re-checks its real size and re-encodes once if needed."
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

                // TARGET SIZE — its own section ABOVE the bitrate, and only
                // when a real probe powers it. Batch setup (or "still
                // analysing") hides it: inside a batch, fitting against ONE
                // video's duration and applying the result to every file
                // would land most of them on the wrong side of the target.
                if contextProbe != nil {
                    Section("Target size (optional)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Know the file size you need — messaging or attachment limits? Type it in MB and tap Fit: the bitrate below is solved to land UNDER that size (an ~8% headroom covers encoder drift and container overhead; audio that doesn't exist isn't budgeted). The output stays a fixed bitrate — re-tap Fit after changing resolution or audio.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            // GUARANTEE state: Fit arms a measured guarantee —
                            // the encode checks its real bytes against the
                            // budget and re-encodes once if the first pass
                            // drifted over. Manual bitrate edits disarm it.
                            if let mb = activeTargetMB {
                                Label(activeTargetLabel(mb), systemImage: "lock.shield.fill")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tint)
                            } else if guaranteedTargetMB != nil {
                                Label("Target cleared — the bitrate no longer matches the Fit solve. Tap Fit again to re-guarantee \(Int(guaranteedTargetMB ?? 0)) MB.",
                                      systemImage: "exclamationmark.circle")
                                    .font(.footnote)
                                    .foregroundStyle(Color(UIColor.systemOrange))
                            }
                            HStack(spacing: 10) {
                                TextField("Target size", text: $fitUnderText)
                                    .focused($fitMBFocused)
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
                            if let msg = fitMessage {
                                Text(msg)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
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
                        // Invalid edit feedback: while the text can't parse
                        // (or is out of range), the readout shows nothing but
                        // the LAST good value still drives Save — say so here.
                        if !bitrateIsValid {
                            Text("Out of range (0.1–40) — still using \(String(format: "%.1f", fixedMbps)) Mbps. Save is disabled while the value is invalid.")
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
                            // The measured target guarantee ships with the
                            // preset ONLY while the bitrate still matches
                            // the Fit solve (activeTargetMB sees to that).
                            targetSizeMB: activeTargetMB
                        )
                        // Editing preserves the preset's identity so the stored
                        // copy is replaced in place.
                        preset.id = existing?.id ?? preset.id
                        onSaved(preset)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    // An invalid typed bitrate (cleared or out of range)
                    // leaves the last good `fixedMbps` in place — refuse to
                    // save until the text is usable again.
                    .disabled(!bitrateIsValid)
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
