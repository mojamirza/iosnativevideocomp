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

/// Editor for a detailed custom preset: codec, resolution class, bitrate mode
/// (adaptive tier / fixed Mbps / exact size target), fps cap, audio bitrate.
/// Pass `existing:` to edit (or duplicate) a preset instead of creating one.
struct PresetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let existing: Preset?
    let onSaved: (Preset) -> Void

    @State private var name: String
    @State private var codec: VideoCodec
    @State private var resolution: ResolutionClass
    @State private var mode: Mode
    @State private var tier: QualityTier
    @State private var fixedMbps: Double
    @State private var sizeTargetMB: Double
    @State private var fpsCapEnabled: Bool
    @State private var fpsCap: Double
    @State private var audioKbps: Double

    enum Mode: String, CaseIterable, Identifiable {
        case adaptive = "Adaptive (optimizer)"
        case fixed = "Fixed bitrate"
        case size = "Target file size"
        var id: String { rawValue }
    }

    init(existing: Preset? = nil, onSaved: @escaping (Preset) -> Void) {
        self.existing = existing
        self.onSaved = onSaved
        let m: Mode
        if existing?.sizeTargetMB != nil {
            m = .size
        } else if existing?.fixedBitrateMbps != nil {
            m = .fixed
        } else {
            m = .adaptive
        }
        _name = State(initialValue: existing?.name ?? "Custom")
        _codec = State(initialValue: existing?.codec ?? .hevc)
        _resolution = State(initialValue: existing?.resolution ?? .keep)
        _mode = State(initialValue: m)
        _tier = State(initialValue: existing?.autoQuality ?? .balanced)
        _fixedMbps = State(initialValue: existing?.fixedBitrateMbps ?? 4)
        _sizeTargetMB = State(initialValue: existing?.sizeTargetMB ?? 100)
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

                Section("Bitrate mode") {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .adaptive:
                        Picker("Quality goal", selection: $tier) {
                            ForEach(QualityTier.allCases) { t in Text(t.label).tag(t) }
                        }
                        Text(tier.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .fixed:
                        VStack(alignment: .leading) {
                            HStack {
                                Slider(value: $fixedMbps, in: 0.3...40, step: 0.1)
                                Text(String(format: "%.1f Mbps", fixedMbps))
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 90, alignment: .trailing)
                            }
                            Text("Lower = smaller file")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    case .size:
                        HStack {
                            Text("Target output size")
                            Spacer()
                            TextField("MB", value: $sizeTargetMB, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.callout.monospacedDigit())
                                .frame(width: 90)
                            Text("MB").foregroundStyle(.secondary)
                        }
                        Text("The optimizer reserves the audio budget first, then derives the video bitrate from the remaining bytes.")
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
                            autoQuality: mode == .adaptive ? tier : nil,
                            fixedBitrateMbps: mode == .fixed ? fixedMbps : nil,
                            sizeTargetMB: mode == .size ? sizeTargetMB : nil,
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
