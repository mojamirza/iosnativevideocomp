import SwiftUI
import AVFoundation

/// Persists user-defined presets in UserDefaults.
enum PresetStore {
    static func loadCustom() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: "customPresets") else { return [] }
        return (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }

    static func saveCustom(_ presets: [Preset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "customPresets")
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
    let onSaved: (Preset) -> Void

    @State private var name: String
    @State private var codec: VideoCodec
    @State private var resolution: ResolutionClass
    @State private var fixedMbps: Double
    @State private var bitrateText: String
    @State private var fpsCapEnabled: Bool
    @State private var fpsCap: Double
    @State private var audioKbps: Double

    init(existing: Preset? = nil, onSaved: @escaping (Preset) -> Void) {
        self.existing = existing
        self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "Custom")
        _codec = State(initialValue: existing?.codec ?? .hevc)
        _resolution = State(initialValue: existing?.resolution ?? .keep)
        let mbps = existing?.fixedBitrateMbps ?? 4
        _fixedMbps = State(initialValue: mbps)
        _bitrateText = State(initialValue: String(format: "%.1f", mbps))
        _fpsCapEnabled = State(initialValue: existing?.fpsCap != nil)
        _fpsCap = State(initialValue: Double(existing?.fpsCap ?? 30))
        _audioKbps = State(initialValue: Double(existing?.audioBitrateKbps ?? 128))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name & codec") {
                    TextField("Preset name", text: $name)
                    Picker("Codec", selection: $codec) {
                        ForEach(VideoCodec.allCases) { c in Text(c.rawValue).tag(c) }
                    }
                    Picker("Resolution", selection: $resolution) {
                        ForEach(ResolutionClass.allCases) { r in Text(r.rawValue).tag(r) }
                    }
                }

                Section("Video bitrate") {
                    VStack(alignment: .leading) {
                        HStack {
                            Slider(value: $fixedMbps, in: 0.3...40, step: 0.1)
                                .onChange(of: fixedMbps) { _, v in
                                    // Only rewrite the text field when the
                                    // change came from the slider — never
                                    // clobber what the user is typing.
                                    if abs((Double(bitrateText.replacingOccurrences(of: ",", with: ".")) ?? -1) - v) > 0.05 {
                                        bitrateText = String(format: "%.1f", v)
                                    }
                                }
                            TextField("Mbps", text: $bitrateText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.callout.monospacedDigit())
                                .frame(width: 70)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: bitrateText) { _, t in
                                    if let v = Double(t.replacingOccurrences(of: ",", with: ".")),
                                       v >= 0.3, v <= 40 {
                                        fixedMbps = v
                                    }
                                }
                            Text("Mbps")
                                .foregroundStyle(.secondary)
                        }
                        Text("Type an exact value above, or drag the bar. Lower = smaller file.")
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
