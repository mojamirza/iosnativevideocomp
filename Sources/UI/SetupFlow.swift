import SwiftUI
import PhotosUI
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
    /// Privacy scrub: keep the source's creation date (location is NEVER
    /// kept). Persisted so the choice sticks across sessions.
    @State private var keepCreationDate = PrivacyScrub.keepCreationDate
    // ADJUST (single video): rotate + trim with a thumbnail filmstrip,
    // plus a custom poster image (embedded as the output's artwork).
    @State private var rotation: Int = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var filmstrip: [UIImage] = []
    @State private var posterItem: PhotosPickerItem?
    @State private var posterData: Data?
    @State private var posterPreview: UIImage?
    // INLINE TRIM PREVIEW: an AVPlayer over the ORIGINAL file that plays
    // exactly [trimStart, trimEnd). What you set is what you see.
    @State private var previewPlayer: AVPlayer?
    @State private var previewIsPlaying = false
    @State private var previewObserver: Any?
    /// FIRST-FRAME PRIMING task for the inline preview — see
    /// startPreviewPriming(at:) below.
    @State private var previewPriming: Task<Void, Never>?

    var availablePresets: [Preset] { Preset.builtIn + customPresets }

    var isBatch: Bool { videos.count > 1 }

    /// LOW-MOTION detector (lecture / screen-recording suggestion): fires on
    /// sources whose own bitrate is tiny relative to pixels×fps, i.e. the
    /// encoder was starved for motion to spend bits on. Threshold: <0.045
    /// bits-per-pixel-frame ≈ static slides with a voice track.
    private var suggestsLectureMode: Bool {
        guard let preset = selectedPreset,
              preset.fpsCap == nil, preset.audioChannels == nil else { return false }
        let candidates = probes.compactMap { $0 }
        guard let p = candidates.first else { return false }
        guard p.nominalFPS > 0, p.sourceSize.width > 0 else { return false }
        let bpp = p.videoDataRate /
            (Double(p.sourceSize.width) * Double(p.sourceSize.height) * Double(p.nominalFPS))
        return bpp < 0.045
    }

    /// Applies the lecture recipe onto a COPY of the selected preset (built-
    /// ins are never mutated): 15 fps cap, a lean bitrate for the output
    /// size, and a forced MONO 48 kbps voice track.
    private func applyLectureMode() {
        guard var preset = selectedPreset else { return }
        preset.fpsCap = 15
        preset.fixedBitrateMbps = max(0.6, min(preset.fixedBitrateMbps, 2.0))
        preset.audioBitrateKbps = 48
        preset.audioChannels = 1
        selectedPreset = preset
    }

    /// Lecture mode is ON when the selected preset already carries the whole
    /// recipe (the explicit long-GOP marker: 15 fps cap + forced mono) -
    /// derived, so switching presets updates it with no stale @State flag.
    private var lectureApplied: Bool {
        guard let preset = selectedPreset else { return false }
        return preset.longGOP
    }

    /// Persist the privacy choice whenever the toggle is moved.
    private func persistPrivacy() {
        PrivacyScrub.keepCreationDate = keepCreationDate
    }

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
                                Text("Analyzing \(videos.count) videos…")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    } else if let probe = singleProbe {
                        probeGrid(probe)
                    } else {
                        HStack {
                            ProgressView()
                            Text("Analyzing source…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }

                    if !isBatch, let probe = singleProbe, probe.duration >= 1.0 {
                        adjustSection(probe)
                    }

                    presetSection
                }
                .padding()
            }
            .background(Color.appScreen)
            // Estimate + Compress live in a PINNED bottom bar: the primary
            // action stays reachable no matter how the preset list grows.
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
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
                // Target mode needs NO probe to save (the target is solved
                // per video when each job starts) — only the solved-bitrate
                // readout needs one, and it hides in batch setup.
                PresetEditorView(contextProbe: isBatch ? nil : singleProbe) { newPreset in
                    savePreset(newPreset)
                }
            }
            .sheet(item: $editingPreset) { preset in
                PresetEditorView(existing: preset,
                                 contextProbe: isBatch ? nil : singleProbe) { updated in
                    savePreset(updated)
                }
            }
            .task {
                await analyze()
            }
            // The privacy policy persists the moment the user moves it —
            // a closed sheet must not lose the choice.
            .onChange(of: keepCreationDate) { _, _ in
                persistPrivacy()
            }
            // Selection feedback: light tick on every preset change.
            .sensoryFeedback(.selection, trigger: selectedPreset?.id)
            // Poster image picked: normalize to JPEG ≤1024px so the embedded
            // artwork's data type is valid regardless of source format
            // (HEIC/PNG/whatever the library hands over).
            .onChange(of: posterItem) { _, item in
                guard let item else { return }
                Task {
                    if let raw = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: raw),
                       let poster = Self.normalizedPoster(img) {
                        posterData = poster
                        posterPreview = UIImage(data: poster)
                    }
                }
            }
        }
    }

    // MARK: pinned bottom bar

    /// Estimated output bytes for the current selection (single or batch).
    private var estimateBytes: Int64? {
        guard analysisDone, selectedPreset != nil else { return nil }
        if isBatch {
            return totalBatchOutBytes(for: selectedPreset!)
        }
        return estimate.map { $0.estimatedBytes }
    }

    /// The probe as the trim window sees it: estimates, preset rows and
    /// plans must all describe the TRIMMED output when a window is set —
    /// otherwise target-size solves against the full length while the
    /// encode runs the trimmed length. The LOGIC lives in the shared,
    /// unit-tested `TrimMath` (the coordinator's resume path uses it too).
    private func isTrimmed(_ p: ProbeResult) -> Bool {
        TrimMath.isTrimmed(start: trimStart, end: trimEnd, duration: p.duration)
    }

    private func trimmed(_ p: ProbeResult) -> ProbeResult {
        TrimMath.apply(p, start: trimStart, end: trimEnd)
    }

    private var littleToGain: Bool {
        guard let out = estimateBytes, selectedPreset != nil else { return false }
        let input = isBatch ? totalInBytes : (singleProbe.map { trimmed($0).fileSize } ?? 0)
        guard input > 0 else { return false }
        // .keep previously excluded itself — but a keep-resolution encode at
        // a low bitrate still gains nothing if the output approaches the
        // input size; the warning must fire there too.
        return Double(out) >= Double(input) * 0.85
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            // H.264 cannot encode 10-bit/HDR — the engine uses HEVC. Tell the
            // user WHY the selected codec chip will be overridden — UNLESS a
            // requested SDR conversion flattens everything to 8-bit 709, in
            // which case H.264 IS legal and this warning would be a lie.
            if let preset = selectedPreset, preset.codec == .h264,
               preset.hdrToSDR != true,
               probes.contains(where: { p in
                   guard let p else { return false }
                   return p.tags.isHDR || p.bitDepth >= 10
               }) {
                Label("10-bit/HDR source — HEVC will be used (H.264 is 8-bit only).",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // LOW-MOTION SUGGESTION (lectures / screen recordings): sources
            // whose own bits-per-pixel are tiny carry almost no motion — a
            // camera-style preset wastes bitrate on 60 fps of stillness.
            // One tap applies the lecture recipe: 15 fps cap + lean bitrate
            // + a MONO voice track.
            if let preset = selectedPreset, suggestsLectureMode, !lectureApplied {
                Label {
                    HStack(spacing: 6) {
                        Text("Low-motion source (lecture / screen recording?)")
                            .font(.footnote)
                        Button("Use lecture mode") {
                            withAnimation { applyLectureMode() }
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                } icon: {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(Color(UIColor.systemTeal))
                }
            } else if lectureApplied {
                Label("Lecture mode on — 15 fps · lean bitrate · mono voice",
                      systemImage: "lightbulb.fill")
                    .font(.footnote)
                    .foregroundStyle(Color(UIColor.systemTeal))
            }

            // PRIVACY SCRUB — deliberate policy, not an accident: outputs
            // never carry location data; the creation date is a choice.
            Toggle(isOn: $keepCreationDate) {
                Label("Keep creation date (location is always removed)",
                      systemImage: "eye.slash")
                    .font(.footnote)
            }
            .tint(.accentColor)

            // BEFORE → AFTER story with a proportional bar.
            if let out = estimateBytes, selectedPreset != nil {
                let input = isBatch ? totalInBytes : (singleProbe.map { trimmed($0).fileSize } ?? 0)
                let inText = ByteCountFormatter.string(fromByteCount: input, countStyle: .file)
                let outText = ByteCountFormatter.string(fromByteCount: out, countStyle: .file)
                let ratio = input > 0 ? Double(out) / Double(input) : 0
                let pct = input > 0 ? (1 - Double(out) / Double(input)) * 100 : 0
                VStack(alignment: .leading, spacing: 7) {
                    if isBatch {
                        Text(String(format: "%d files · %@ → ≈ %@ (−%.0f%%)",
                                    videos.count, inText, outText, max(0, pct)))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text(String(format: "%@ → ≈ %@ (−%.0f%%)", inText, outText, max(0, pct)))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    // The EFFECTIVE planned bitrate — same plan() as the row
                    // above, so bar and row can never disagree. "(capped)"
                    // says when the source (not the user) limited it.
                    if !isBatch, let est = estimate {
                        Text("≈ \(SizeMath.mbpsLabel(est.videoBitrate)) Mbps"
                                + (est.bitrateCapped ? " (capped)" : ""))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if isBatch, let preset = selectedPreset,
                              let avg = batchAvgBitrate(for: preset) {
                        Text("avg \(SizeMath.mbpsLabel(avg)) Mbps")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // Proportional bar: tinted portion = output size share.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.systemFill))
                            Capsule().fill(ratio <= 1 ? Color.accentColor : Color(.systemOrange))
                                .frame(width: max(4, min(1, ratio) * geo.size.width))
                        }
                    }
                    .frame(height: 6)
                    if littleToGain {
                        Label("Little to gain — the source is already leaner than this preset targets.",
                              systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color(UIColor.systemOrange))
                    }
                }
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
        .padding(.horizontal, 16)
        // Top inset only matters when content sits above the button (estimate,
        // warnings) — otherwise it is dead blank space in front of the bar.
        .padding(.top, hasContextRows ? 10 : 6)
        .padding(.bottom, 4)
        // The material must run THROUGH the home-indicator strip: safeAreaInset
        // layouts this view INSIDE the safe area, so a plain background stops
        // at the safe-area edge and the scroll content peeks through a blank
        // strip UNDER the bar. Extending the fill removes it.
        .background(Rectangle()
            .fill(.regularMaterial)
            .ignoresSafeArea(edges: .bottom))
    }

    /// Whether the estimate / warning rows exist above the Compress button —
    /// controls the bar's top inset so no blank band fronts the button.
    private var hasContextRows: Bool {
        errorText != nil
            || (estimateBytes != nil && selectedPreset != nil)
    }

    // MARK: subviews

    /// Batch header: count + total input size.
    // MARK: adjust (single video)

    /// Rotate + trim controls with a thumbnail filmstrip: 8 evenly spaced
    /// frames; the ones outside the trim window dim so the selection is
    /// visible without a scrubber. Handles below: sliders PLUS ±1 s / ±10 s
    /// nudge buttons (mouse-precision falls short for frame-exact trims on
    /// an iPad touch target), and an inline player that previews exactly
    /// the selected window.
    private func adjustSection(_ probe: ProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adjust").font(.caption.bold()).foregroundStyle(.secondary)

            HStack(spacing: 2) {
                if filmstrip.isEmpty {
                    ForEach(0..<8, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 44)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(filmstrip.indices, id: \.self) { i in
                        let t = probe.duration * (Double(i) + 0.5) / Double(filmstrip.count)
                        let inside = t >= trimStart && t <= trimEnd
                        Image(uiImage: filmstrip[i])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 44)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .opacity(inside ? 1 : 0.25)
                    }
                }
            }

            trimHandleRow(label: "Start", isStart: true, probe: probe)
            trimHandleRow(label: "End", isStart: false, probe: probe)
            Text("Keeping \(timeString(trimEnd - trimStart)) of \(timeString(probe.duration))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // INLINE PREVIEW: plays the ORIGINAL file from trimStart and
            // cuts off at the live trimEnd — the selection, not the asset.
            if let url = videos.first?.url {
                HStack(spacing: 10) {
                    Button {
                        togglePreview(url)
                    } label: {
                        Label(previewIsPlaying ? "Stop" : "Preview selection",
                              systemImage: previewIsPlaying ? "stop.fill" : "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    if previewIsPlaying {
                        Text("\(timeString(trimStart)) → \(timeString(trimEnd))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if previewIsPlaying, let p = previewPlayer {
                    TrimPreview(player: p)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            // Adjusting while previewing restarts from the new window edge.
            .onChange(of: trimStart) { _, _ in if previewIsPlaying { stopPreview() } }
            .onChange(of: trimEnd) { _, _ in if previewIsPlaying { stopPreview() } }

            HStack {
                Text("Rotate").font(.caption2)
                Spacer()
                Picker("Rotate", selection: $rotation) {
                    Text("Native").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }

            // CUSTOM POSTER: any image the user picks is normalized to
            // JPEG ≤1024px and embedded as the output's QuickTime artwork —
            // Files/Finder and players show it as the video's thumbnail.
            HStack(spacing: 12) {
                Group {
                    if let preview = posterPreview {
                        Image(uiImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 64, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(posterPreview == nil ? "Poster: automatic frame" : "Custom poster set")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $posterItem, matching: .images) {
                            Text("Choose image…")
                                .font(.caption.weight(.semibold))
                        }
                        if posterPreview != nil {
                            Button("Use automatic") {
                                posterItem = nil
                                posterData = nil
                                posterPreview = nil
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        // Leaving the setup sheet (or scrolling the section away) must not
        // leave preview audio playing behind the app.
        .onDisappear {
            stopPreview()
        }
    }

    /// AVPlayerLayer host for the inline trim preview — a plain layer
    /// player (no AVPlayerViewController), sized in the host's
    /// layoutSubviews so the resizeAspect video always fills the frame.
    private struct TrimPreview: UIViewRepresentable {
        let player: AVPlayer

        // NOT private: makeUIView/updateUIView are UIViewRepresentable's
        // (public) protocol witnesses and expose this type in their
        // signatures — a private nested class here fails to compile
        // (CI round 42402406446).
        final class HostView: UIView {
            override func layoutSubviews() {
                super.layoutSubviews()
                for layer in layer.sublayers ?? [] {
                    if let playerLayer = layer as? AVPlayerLayer {
                        playerLayer.frame = bounds
                    }
                }
            }
        }

        func makeUIView(context: Context) -> HostView {
            let view = HostView()
            view.backgroundColor = .black
            let layer = AVPlayerLayer()
            layer.player = player
            layer.videoGravity = .resizeAspect
            view.layer.addSublayer(layer)
            return view
        }

        func updateUIView(_ uiView: HostView, context: Context) {
            // The layer is attached once in makeUIView; sizing lives in
            // the host's layoutSubviews.
        }
    }

    /// Clamp helpers keep both handle puzzles consistent (≥ 0.5 s window,
    /// within [0, duration]) across slider AND every nudge direction.
    private func clampedStart(_ v: Double) -> Double {
        min(max(0, v), max(0, trimEnd - 0.5))
    }

    private func clampedEnd(_ v: Double, probe: ProbeResult) -> Double {
        max(min(probe.duration, v), min(trimStart + 0.5, probe.duration))
    }

    private func nudge(_ isStart: Bool, by seconds: Double, probe: ProbeResult) {
        if isStart {
            trimStart = clampedStart(trimStart + seconds)
        } else {
            trimEnd = clampedEnd(trimEnd + seconds, probe: probe)
        }
    }

    /// One draggable trim handle: label, ±10 s + ±1 s nudges, the slider
    /// itself, and the live timestamp. Touch sliders alone bottom out at
    /// whole-second precision — the nudge buttons exist for exact edges.
    private func trimHandleRow(label: String, isStart: Bool, probe: ProbeResult) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .frame(width: 30, alignment: .leading)
            nudgeButton("−10", isStart: isStart, by: -10, probe: probe,
                        disabled: isStart ? trimStart <= 0.001
                                          : trimEnd <= trimStart + 0.5 + 1e-6)
            nudgeButton("−1", isStart: isStart, by: -1, probe: probe,
                        disabled: isStart ? trimStart <= 0.001
                                          : trimEnd <= trimStart + 0.5 + 1e-6)
            if isStart {
                Slider(value: Binding(
                    get: { trimStart },
                    set: { trimStart = clampedStart($0) }),
                       in: 0...max(0, trimEnd - 0.5))
                    .accessibilityLabel("Trim start")
            } else {
                Slider(value: Binding(
                    get: { trimEnd },
                    set: { trimEnd = clampedEnd($0, probe: probe) }),
                       in: min(trimStart + 0.5, probe.duration)...probe.duration)
                    .accessibilityLabel("Trim end")
            }
            nudgeButton("+1", isStart: isStart, by: 1, probe: probe,
                        disabled: isStart ? trimEnd - trimStart <= 0.5 + 1e-6
                                          : trimEnd >= probe.duration - 0.001)
            nudgeButton("+10", isStart: isStart, by: 10, probe: probe,
                        disabled: isStart ? trimEnd - trimStart <= 0.5 + 1e-6
                                          : trimEnd >= probe.duration - 0.001)
            Text(timeString(isStart ? trimStart : trimEnd))
                .font(.caption2.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func nudgeButton(_ title: String, isStart: Bool, by seconds: Double,
                             probe: ProbeResult, disabled: Bool) -> some View {
        Button {
            nudge(isStart, by: seconds, probe: probe)
        } label: {
            Text(title)
                .font(.caption2.monospacedDigit())
                .frame(width: 30, height: 22)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .accessibilityLabel("\(isStart ? "Trim start" : "Trim end") \(title)")
    }

    private func togglePreview(_ url: URL) {
        if previewIsPlaying {
            stopPreview()
            return
        }
        let player: AVPlayer
        if let p = previewPlayer,
           (p.currentItem?.asset as? AVURLAsset)?.url == url {
            player = p
        } else {
            // Different file than the last preview: drop the old player AND
            // its periodic observer (the token was previously never removed
            // — the observer's closure outlived the player and leaked, and
            // every new file stacked another one).
            stopPreview()
            player = AVPlayer(url: url)
            previewPlayer = player
        }
        // The cutoff observer is (re)attached on every start and removed on
        // every stop: it cuts playback at the live trimEnd (State reads
        // through storage, so dragging the end handle while playing is
        // honored too).
        previewObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main) { time in
                if CMTimeGetSeconds(time) >= trimEnd
                    || CMTimeGetSeconds(time) < trimStart - 0.05 {
                    stopPreview()
                }
            }
        previewIsPlaying = true
        startPreviewPriming(player, at: trimStart)
    }

    /// FIRST-FRAME PRIMING (the 180°-rotation flash): a fresh AVPlayer has
    /// not loaded its tracks yet — playing immediately lets the player
    /// layer present the very first decoded frame BEFORE the track's
    /// rotation transform has been applied, so a video recorded upside
    /// down (180° transform) flashes rotated for one frame and then
    /// corrects. Wait for the item to be READY, seek to the window start
    /// with ZERO tolerance (forces the renderer to decode the exact frame
    /// with the full track geometry), and only then start playback. The
    /// preview view shows plain black while priming.
    private func startPreviewPriming(_ player: AVPlayer, at startSeconds: Double) {
        previewPriming?.cancel()
        let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        guard let item = player.currentItem else { return }
        if item.status == .readyToPlay {
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            return
        }
        previewPriming = Task { @MainActor in
            // Bounded wait (50 ms cadence, 10 s cap): a slow container must
            // not leave the preview stuck — past the cap, play whatever the
            // player has (the previous behavior).
            var waitedNs = 0
            while item.status == .unknown, waitedNs < 10_000_000_000,
                  !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waitedNs += 50_000_000
            }
            guard !Task.isCancelled else { return }
            // await the seek — see the matching comment in
            // OutputPlayerSheet.primeThenPlay (async-context overload).
            await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        }
    }

    private func stopPreview() {
        previewPriming?.cancel()
        previewPriming = nil
        if let previewObserver, let p = previewPlayer {
            p.removeTimeObserver(previewObserver)
        }
        previewObserver = nil
        previewPlayer?.pause()
        previewIsPlaying = false
    }

    private func timeString(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    /// 8 evenly spaced frames via AVAssetImageGenerator (keyframe-tolerant,
    /// small). Failures just leave placeholders.
    private func loadFilmstrip(_ probe: ProbeResult, url: URL) async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        var imgs: [UIImage] = []
        let count = 8
        for i in 0..<count {
            let t = CMTime(seconds: probe.duration * (Double(i) + 0.5) / Double(count),
                           preferredTimescale: 600)
            if let (img, _) = try? await gen.image(at: t) {
                imgs.append(UIImage(cgImage: img))
            }
        }
        filmstrip = imgs
    }

    /// Poster normalization: ≤1024px JPEG so the embedded artwork's data
    /// type is always valid regardless of the picked format (HEIC/PNG/…).
    /// The renderer format pins scale = 1 — a plain UIGraphicsImageRenderer
    /// uses the SCREEN scale (3× on Pro displays) and quietly produces
    /// 3072px images.
    private static func normalizedPoster(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 1024
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(),
                          height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.9)
    }

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

    /// The single source's probe (nil for batches or while analyzing).
    /// Previously `probes.first ?? nil` — in a batch it handed VIDEO 1's
    /// probe to everything that read it (preset rows then showed one video's
    /// estimate next to the batch total). A batch has NO single probe.
    private var singleProbe: ProbeResult? {
        guard !isBatch else { return nil }
        return probes.compactMap { $0 }.first ?? nil
    }

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
                        // Per-video OUTPUT estimate next to the input size.
                        if let p = probes[i],
                           analysisDone, let preset = selectedPreset {
                            Text(String(format: "→ ≈ %.0f MB",
                                        QualitySizeOptimizer.plan(preset: preset, probe: p).estimatedSizeMB()))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.tint)
                        }
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
                // The SELECTED row renders the live variant (lecture-mode
                // tweaks mutate a copy with the same id) so its numbers match
                // the estimate bar.
                let displayPreset = (selectedPreset?.id == preset.id) ? selectedPreset! : preset
                PresetRow(preset: displayPreset,
                          isSelected: selectedPreset?.id == preset.id,
                          probe: singleProbe.map({ trimmed($0) }),
                          batchTotalBytes: isBatch ? totalBatchOutBytes(for: preset) : nil,
                          batchAvgBitrate: isBatch ? batchAvgBitrate(for: preset) : nil) {
                    selectedPreset = preset
                    // The tap IS the selection: persist it now — the old code
                    // only persisted editor saves, so the last-used preset
                    // never stuck for plain row selections.
                    PresetStore.setLastUsedPreset(preset.id)
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

    /// Duration-weighted average planned VIDEO bitrate across the batch —
    /// the batch row previously printed the PRESET's typed bitrate while
    /// every plan actually ran the source-capped (or target-solved) value:
    /// the number on the row and the encode disagreed.
    private func batchAvgBitrate(for preset: Preset) -> Int? {
        var bits: Double = 0
        var seconds: Double = 0
        for p in probes where p != nil {
            let plan = QualitySizeOptimizer.plan(preset: preset, probe: p!)
            bits += Double(plan.videoBitrate) * plan.duration
            seconds += plan.duration
        }
        guard seconds > 0 else { return nil }
        return Int(bits / seconds)
    }

    /// Total ESTIMATED OUTPUT for the whole batch with a given preset.
    private func totalBatchOutBytes(for preset: Preset) -> Int64? {
        guard analysisDone else { return nil }
        var valid = 0
        var total: Int64 = 0
        for p in probes where p != nil {
            total += QualitySizeOptimizer.plan(preset: preset, probe: p!).estimatedBytes
            valid += 1
        }
        return valid > 0 ? total : nil
    }

    private var estimate: OptimizerPlan? {
        guard let probe = singleProbe, let preset = selectedPreset else { return nil }
        return QualitySizeOptimizer.plan(preset: preset, probe: trimmed(probe))
    }

    private var buttonTitle: String {
        if !analysisDone { return "Analyzing…" }
        guard selectedPreset != nil else { return "Choose a preset" }
        return isBatch ? "Compress \(videos.count) videos" : "Compress"
    }

    private var canStart: Bool {
        guard analysisDone, selectedPreset != nil else { return false }
        return probes.contains { $0 != nil }
    }

    private func start() {
        guard let preset = selectedPreset, analysisDone else { return }
        // Commit-time truth for "last used": the preset that actually ran
        // (covers the lecture-mode variant too, which shares the base id).
        PresetStore.setLastUsedPreset(preset.id)
        for i in videos.indices {
            guard let rawProbe = probes[i] else { continue }
            // Single video: plan against the TRIMMED window (estimates, the
            // target-size solve and the encode must all agree).
            let probe = isBatch ? rawProbe : trimmed(rawProbe)
            var plan = QualitySizeOptimizer.plan(preset: preset, probe: probe)
            if !isBatch {
                // Per-video adjustments (single video only): rotation, the
                // trim window and the poster image live on the plan, not the
                // preset.
                plan.rotationDegrees = rotation
                if isTrimmed(rawProbe) {
                    plan.trimStart = trimStart
                    plan.trimEnd = trimEnd
                }
                // Poster: the user-picked image (nil = automatic frame).
                plan.posterData = posterData
            }
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
        // PARALLEL PROBES: a batch of N videos previously probed one-by-one
        // (N × asset open + parse before the sheet became usable). A bounded
        // task group keeps memory flat while cutting the wait to ~N/4.
        var failures = 0
        await withTaskGroup(of: (Int, ProbeResult?).self) { group in
            var next = 0
            let width = min(4, videos.count)
            // Each completion pulls the next index into the group.
            func addNext() {
                guard next < videos.count else { return }
                let i = next
                next += 1
                let url = videos[i].url
                group.addTask {
                    do {
                        let p = try await ProbeResult.probe(url: url)
                        return (i, (p.duration.isNaN || p.duration <= 0) ? nil : p)
                    } catch {
                        return (i, nil)
                    }
                }
            }
            for _ in 0..<width { addNext() }
            for await (i, result) in group {
                probes[i] = result
                if result == nil { failures += 1 }
                addNext()
            }
        }
        // Single video: initialize the trim window to the full duration.
        // FRAMEGRAB DECOUPLED: Compress must be usable the instant the
        // probes finish — the 8-frame filmstrip load below can take whole
        // seconds and blocking the ONLY gate that enables the button behind
        // it froze the screen's primary action.
        if !isBatch, let p = probes.compactMap({ $0 }).first {
            trimEnd = p.duration
        }
        analysisDone = true
        if let id = selectedPreset?.id {
            PresetStore.setLastUsedPreset(id)
        }
        if !isBatch, let p = probes.compactMap({ $0 }).first {
            await loadFilmstrip(p, url: videos[0].url)
        }
        if failures > 0 {
            errorText = failures == videos.count
                ? "None of the selected files could be analyzed; they may be unsupported."
                : "\(failures) of \(videos.count) videos couldn't be analyzed and will be skipped."
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
    /// Duration-weighted average of the PLANNED bitrates across the batch —
    /// what the encoder will actually run, not what was typed.
    var batchAvgBitrate: Int?
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
                        TagChip(text: preset.resolution.displayName)
                        if preset.audioChannels == 1 {
                            TagChip(text: "Mono voice")
                        }
                        if preset.hdrToSDR == true {
                            TagChip(text: "SDR out")
                        }
                        // Bitrate intentionally NOT a chip: it's shown at the
                        // trailing side (and in the estimate card) — a second
                        // dark pill here just cluttered the row.
                    }
                }
                Spacer()
                if let probe {
                    let plan = QualitySizeOptimizer.plan(preset: preset, probe: probe)
                    VStack(alignment: .trailing, spacing: 2) {
                        if preset.targetSizeMB != nil {
                            if !plan.targetFeasible {
                                // No rate, even the floor, fits this clip.
                                Text("Too small")
                                    .font(.callout.weight(.bold))
                                    .foregroundStyle(.red)
                                Text("target can't fit this video's length")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                // GUARANTEED target: the promise first, the
                                // honest SOLVED plan underneath (expected
                                // bytes INCLUDE container overhead).
                                Text(String(format: "≤ %.0f MB",
                                            preset.targetSizeMB ?? 0))
                                    .font(.callout.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.tint)
                                Text("≈ \(ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file)) · \(SizeMath.mbpsLabel(plan.videoBitrate)) Mbps")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(String(format: "≈ %.0f MB",
                                        plan.estimatedSizeMB()))
                                .font(.callout.weight(.bold).monospacedDigit())
                                .foregroundStyle(.tint)
                            // The PLAN's bitrate (target-solved or capped by
                            // the source) — what the encode actually runs,
                            // NOT the preset's typed value.
                            Text("\(SizeMath.mbpsLabel(plan.videoBitrate)) Mbps"
                                    + (plan.bitrateCapped ? " (capped)" : ""))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let totalBytes = batchTotalBytes {
                    VStack(alignment: .trailing, spacing: 2) {
                        // Decimal MB (matching ByteCountFormatter), not MiB —
                        // the old ÷ 1_048_576 displayed a different unit than
                        // every other size in the UI.
                        Text(String(format: "≈ %.0f MB total", Double(totalBytes) / 1_000_000))
                            .font(.callout.weight(.bold).monospacedDigit())
                            .foregroundStyle(.tint)
                        if let avg = batchAvgBitrate {
                            // Duration-weighted average of the per-video
                            // PLANS — with targets (solved per video) and
                            // capped sources this can differ a lot from the
                            // preset's typed number.
                            Text("avg \(SizeMath.mbpsLabel(avg)) Mbps")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
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
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            // Subtle system fill — the old .thinMaterial capsule read as a
            // dark "black box" and clashed with the row background.
            .background(Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
