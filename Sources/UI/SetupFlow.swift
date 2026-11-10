import SwiftUI
import PhotosUI
import AVFoundation

/// One imported video on its way into the setup flow (batch-capable).
struct PickedVideo: Identifiable {
    let id = UUID()
    let url: URL
    var thumbnail: UIImage?
}

/// DURABLE SETUP SESSION: every piece of setup state a user could lose to a
/// RE-PRESENTED sheet. RootView's compact/regular shell swap (dragging the
/// Split View divider across the horizontal size-class threshold) tears the
/// setup sheet's whole subtree down and re-presents it with `showingSetup`
/// still true — @State dies with the subtree, so the v1.8.0 fix preserved
/// only the IMPORT COPIES while the visible session (probes, the trim
/// window, rotation, a picked poster, the preset choice) reset silently.
/// The dangerous variant: a 5-second trim vanishes without any visible
/// sign, and the next Compress encodes the UNTRIMMED clip.
///
/// Owned by RootView (`@StateObject`), passed into every built
/// SetupFlowView. Analyze() is IDEMPOTENT against the same video set
/// (shell-swap replay adds nothing) and calls `reset(for:)` itself when a
/// DIFFERENT video set arrives, so RootView's import paths need no
/// reset calls of their own.
@MainActor
final class SetupSession: ObservableObject {
    @Published var probes: [ProbeResult?] = []
    @Published var analysisDone = false
    @Published var errorText: String?
    @Published var selectedPreset: Preset?
    @Published var customPresets: [Preset] = PresetStore.loadCustom()
    // ADJUST (single video): trim window, rotation, poster.
    @Published var rotation = 0
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    /// Filmstrip frames — slot i owns one eighth of the strip (nil slot =
    /// failed grab; see SetupFlowView for the full contract).
    @Published var filmstrip: [UIImage?] = []
    @Published var posterData: Data?
    @Published var posterPreview: UIImage?

    /// Paths whose probes/adjust-state this session describes. A shell-swap
    /// re-presentation of the SAME import reuses everything above; a
    /// genuinely NEW import (different set) starts fresh — reset() below.
    private(set) var videoKeys: [String] = []

    /// Fresh session state for a new import.
    func reset(for videos: [PickedVideo]) {
        probes = Array(repeating: nil, count: videos.count)
        analysisDone = false
        errorText = nil
        selectedPreset = nil
        rotation = 0
        trimStart = 0
        trimEnd = 0
        filmstrip = []
        posterData = nil
        posterPreview = nil
        videoKeys = videos.map { $0.url.standardizedFileURL.path }
    }
}

/// Shown right after picking video(s): probe summary, preset selection with a
/// live *estimated output size / bitrate*, and the Compress button.
/// A batch (N > 1) applies ONE preset to all videos; per-file estimates and
/// totals are shown live. A single video looks exactly like the old flow.
struct SetupFlowView: View {
    @EnvironmentObject private var coordinator: JobCoordinator

    let videos: [PickedVideo]
    let onDone: () -> Void
    /// DURABLE SETUP SESSION — owned by RootView (SetupSession doc below).
    /// The shell swap across the compact/regular threshold tears this
    /// sheet's whole subtree down and re-presents it; @State dies with the
    /// subtree, so everything worth keeping lives HERE.
    @ObservedObject var session: SetupSession

    // DURABLE per-import state (see SetupSession): probes, analysis flag,
    // preset selection, adjust state (trim/rotation), the filmstrip frames
    // and the poster. A shell swap (dragging the Split View divider over
    // the compact/regular threshold) tears the sheet's subtree down and
    // re-presents it; @State dies with the subtree — sessions live on the
    // RootView-owned ObservableObject instead. Accessed below through
    // GET/SET computed properties of the same names, so every existing
    // read/write site stays untouched.
    //
    // TRANSIENT UI state stays @State: it reinitializes on the swap and
    // nothing in the file depends on it surviving (a re-presented sheet
    // starts harmless).

    // Each durable field is a plain pass-through to the session — reads
    // AND writes (`probes[i] = …`, `selectedPreset = …`) both route there.
    private var probes: [ProbeResult?] {
        get { session.probes }
        nonmutating set { session.probes = newValue }
    }
    private var analysisDone: Bool {
        get { session.analysisDone }
        nonmutating set { session.analysisDone = newValue }
    }
    private var errorText: String? {
        get { session.errorText }
        nonmutating set { session.errorText = newValue }
    }
    private var selectedPreset: Preset? {
        get { session.selectedPreset }
        nonmutating set { session.selectedPreset = newValue }
    }
    private var customPresets: [Preset] {
        get { session.customPresets }
        nonmutating set { session.customPresets = newValue }
    }
    private var rotation: Int {
        get { session.rotation }
        nonmutating set { session.rotation = newValue }
    }
    private var trimStart: Double {
        get { session.trimStart }
        nonmutating set { session.trimStart = newValue }
    }
    private var trimEnd: Double {
        get { session.trimEnd }
        nonmutating set { session.trimEnd = newValue }
    }
    private var filmstrip: [UIImage?] {
        get { session.filmstrip }
        nonmutating set { session.filmstrip = newValue }
    }
    private var posterData: Data? {
        get { session.posterData }
        nonmutating set { session.posterData = newValue }
    }
    private var posterPreview: UIImage? {
        get { session.posterPreview }
        nonmutating set { session.posterPreview = newValue }
    }

    // TRANSIENT UI state: editor sheets, inline preview plumbing, "Change…"
    // expansion, the PhotosPicker's item cache.
    @State private var showEditor = false
    @State private var editingPreset: Preset?
    @State private var posterItem: PhotosPickerItem?
    // INLINE TRIM PREVIEW: an AVPlayer over the ORIGINAL file that plays
    // exactly [trimStart, trimEnd). What you set is what you see.
    @State private var previewPlayer: AVPlayer?
    @State private var previewIsPlaying = false
    @State private var previewObserver: Any?
    /// FIRST-FRAME PRIMING task for the inline preview — see
    /// startPreviewPriming(at:) below.
    @State private var previewPriming: Task<Void, Never>?
    /// ABOVE THE FOLD: only the SELECTED preset shows by default; “Change…”
    /// expands the full list (selecting a row collapses back) so the size
    /// estimate and Compress stay reachable without scrolling past 5+ preset
    /// rows.
    @State private var showingAllPresets = false
    /// RE-ENTRANT START GUARD: the Compress button stays enabled until the
    /// sheet actually dismisses (onDone → showingSetup = false → dismissal
    /// animation), so a fast double tap re-enters the still-mounted button's
    /// action and enqueues the whole batch TWICE — per video: two SwiftData
    /// rows (insert+save is real work, widest window precisely on large
    /// batches), two encodes racing one import copy, and when the first
    /// job completes it removes that copy so the duplicate can never run.
    /// Transient by design: a fresh sheet is a fresh instance.
    @State private var didEnqueue = false

    var availablePresets: [Preset] { Preset.builtIn + customPresets }

    var isBatch: Bool { videos.count > 1 }

    init(videos: [PickedVideo], onDone: @escaping () -> Void,
         session: SetupSession) {
        self.videos = videos
        self.onDone = onDone
        self.session = session
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
                    } else if analysisDone {
                        // FAILED PROBE (single video): analyze() completed
                        // without a usable probe — an indeterminate spinner
                        // here reads as an app hang (the bottom bar says
                        // "None of the selected files could be analyzed"
                        // while the row spins forever; the only exit is
                        // Cancel). Say what the batch list says per row:
                        // this video failed to read.
                        Label("This video couldn't be analyzed — it may be unsupported.",
                              systemImage: "xmark.octagon")
                            .font(.callout)
                            .foregroundStyle(.red)
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

                    // BOTTOM BREATHING ROOM: the pinned estimate/Compress bar
                    // is a safeAreaInset, but the scrolled content still ran
                    // FLUSH against it — the collapsed preset's "Change…"
                    // button sat half behind the bar's material edge on
                    // device. Extra padding keeps the last control clearly
                    // above the bar (and gives the sheet a taller, calmer
                    // bottom).
                    Spacer().frame(height: 28)
                }
                .padding()
                .padding(.bottom, 8)
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
            .navigationDestination(isPresented: $showEditor) {
                // PUSHED inside this stack — the editor sheet-over-sheet let
                // the setup sheet's material show through underneath (two
                // stacked cards); a push reads as one continuous flow.
                // Target mode needs NO probe to save (the target is solved
                // per video when each job starts) — only the solved-bitrate
                // readout needs one, and it hides in batch setup.
                PresetEditorView(embeddedInHostStack: true,
                                 contextProbe: isBatch ? nil : singleProbe) { newPreset in
                    savePreset(newPreset)
                }
            }
            .navigationDestination(item: $editingPreset) { preset in
                PresetEditorView(embeddedInHostStack: true,
                                 existing: preset,
                                 contextProbe: isBatch ? nil : singleProbe) { updated in
                    savePreset(updated)
                }
            }
            .task {
                await analyze()
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

            // TARGET-SIZE GATE (single video): the button is disabled BELOW —
            // this row is the WHY. The preset's target can't fit the clip's
            // length, so every encode would end in the same verification
            // failure; the fix is the user picking a larger target.
            if singleInfeasible {
                Label("This target can't fit the video's length — pick a larger target.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            // BEFORE → AFTER story. The delta uses THE one shared label:
            // growth reads “+8%” (the old max(0, pct) hid it behind “−0%”)
            // and sub-percent savings say “−<1%”.
            if let out = estimateBytes, selectedPreset != nil {
                let input = isBatch ? totalInBytes : (singleProbe.map { trimmed($0).fileSize } ?? 0)
                let inText = ByteCountFormatter.string(fromByteCount: input, countStyle: .file)
                let outText = ByteCountFormatter.string(fromByteCount: out, countStyle: .file)
                let delta = SizeMath.deltaLabel(inBytes: input, outBytes: out)
                // The proportional bar is GONE: an unlabeled tinted fill read
                // as encode PROGRESS ("is it 55% done?"). The before → after
                // line above already says exactly what the share was — the
                // delta label in it IS the explanation.
                VStack(alignment: .leading, spacing: 7) {
                    if isBatch {
                        Text("\(videos.count) files · \(inText) → ≈ \(outText) (\(delta))")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(delta.hasPrefix("+") ? .orange : .primary)
                    } else {
                        Text("\(inText) → ≈ \(outText) (\(delta))")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(delta.hasPrefix("+") ? .orange : .primary)
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
                    if littleToGain {
                        Label("Little to gain — the source is already leaner than this preset targets.",
                              systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
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
            .controlSize(.large)
            // singleInfeasible / batchNothingStartable: an unreachable
            // target is not a starting signal — the full encode could only
            // end in the verification failure the row already predicted
            // ("Too small" / "Too small for this length").
            // didEnqueue: commit already ran (double-tap re-entrancy) — the
            // remaining taps until dismissal are no-ops.
            .disabled(!canStart || singleInfeasible || batchNothingStartable
                      || didEnqueue)
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
            || singleInfeasible
    }

    // MARK: subviews

    // MARK: adjust (single video)

    /// GROUPED-LIST HEADER: footnote-weight, secondary — matching the
    /// FORM headers ("Name & codec", "Built-in") in sentence case, so the
    /// custom scroll view and every Form in the app speak the same
    /// typography. (The old .uppercased() small-caps read as a different
    /// app — HIG uses small caps only inside Forms, which already carry
    /// it natively.)
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Rotate + trim controls: a Photos-style filmstrip with draggable
    /// yellow end handles (TrimFilmstripPicker below) and an inline player
    /// that previews exactly the selected window.
    private func adjustSection(_ probe: ProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Adjust")

            // PHOTOS-STYLE TRIM: one filmstrip with draggable yellow end
            // handles (live time labels) and a middle drag that moves the
            // whole window — replaces the two slider rows + nudge buttons.
            TrimFilmstripPicker(frames: filmstrip,
                                start: $session.trimStart,
                                end: $session.trimEnd,
                                duration: probe.duration,
                                onDrag: { stopPreview() })
            Text("Keeping \(timeString(trimEnd - trimStart)) of \(timeString(probe.duration))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // INLINE PREVIEW: plays the ORIGINAL file from trimStart and
            // cuts off at the live trimEnd — the selection, not the asset.
            // ONE host view for the preview controls: a modifier cannot
            // postfix an `if` statement inside a ViewBuilder (CI round
            // 42403927994), so the trim-change observers below attach to
            // this VStack instead of the bare `if let`.
            if let url = videos.first?.url {
                VStack(spacing: 10) {
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
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.tileRadius))
                    }
                }
                // Adjusting while previewing restarts from the new window edge.
                .onChange(of: trimStart) { _, _ in if previewIsPlaying { stopPreview() } }
                .onChange(of: trimEnd) { _, _ in if previewIsPlaying { stopPreview() } }
            }

            HStack {
                Text("Rotate").font(.caption2)
                Spacer()
                Picker("Rotate", selection: $session.rotation) {
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
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: AppTheme.largeCardRadius))
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
        // honored too). MUXER ANCHOR: trim values are OUTPUT-timeline
        // seconds, but this player runs on the SOURCE timeline, which
        // starts at the probe's startOffset (edited/exported clips carry a
        // nonzero anchor). The engine seeks the encoder the same way
        // (plan.source.startOffset + trim) — the preview must, too.
        let anchor = singleProbe?.startOffset ?? 0
        previewObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main) { time in
                if CMTimeGetSeconds(time) >= anchor + trimEnd
                    || CMTimeGetSeconds(time) < anchor + trimStart - 0.05 {
                    stopPreview()
                }
            }
        previewIsPlaying = true
        startPreviewPriming(player, at: anchor + trimStart)
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
        SizeMath.durationLabel(s)
    }

    /// 8 evenly spaced frames via AVAssetImageGenerator (keyframe-tolerant,
    /// small). The result keeps ALL 8 SLOTS — a failed grab leaves that slot
    /// nil (rendered as a placeholder tile): resizing the surviving frames
    /// to fill the row would move every later frame off the time position
    /// the trim window reads for it.
    private func loadFilmstrip(_ probe: ProbeResult, url: URL) async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let count = 8
        var imgs: [UIImage?] = Array(repeating: nil, count: count)
        for i in 0..<count {
            // MUXER ANCHOR: the strip's labels count OUTPUT-timeline time
            // (0…duration), so its frames must be sampled at
            // startOffset + slot seconds — the same raw-time mapping the
            // engine uses when it reads the trim window on the real file.
            // Without the anchor a shifted-source strip showed frames from
            // BEFORE the export anchor ("what you set is what you see"
            // violated by exactly the anchor amount).
            let t = CMTime(seconds: probe.startOffset
                                + probe.duration * (Double(i) + 0.5) / Double(count),
                           preferredTimescale: 600)
            if let (img, _) = try? await gen.image(at: t) {
                imgs[i] = UIImage(cgImage: img)
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
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppTheme.tileRadius))
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
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: AppTheme.largeCardRadius))
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
            sectionHeader("Videos")
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
                    Text((videos[i].url.lastPathComponent as NSString).deletingPathExtension)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(ByteCountFormatter.string(fromByteCount: probes[i]?.fileSize ?? 0, countStyle: .file))
                            if let p = probes[i] {
                                Text("·")
                                Text(SizeMath.durationLabel(p.duration))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // Per-video OUTPUT estimate next to the input size.
                        if let p = probes[i],
                           analysisDone, let preset = selectedPreset {
                            let rowPlan = QualitySizeOptimizer.plan(preset: preset, probe: p)
                            if rowPlan.targetFeasible {
                                Text(String(format: "→ ≈ %.0f MB",
                                            rowPlan.estimatedSizeMB()))
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.tint)
                            } else {
                                // Infeasible: this row will NOT be enqueued
                                // (the batch gate in start() skips it) — a
                                // fake "≈ X MB" would promise an output the
                                // planner already knows it can't reach.
                                Text("Too small for this length")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.red)
                            }
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
                .background(Color.appCard, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
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
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.tileRadius))
            } else {
                RoundedRectangle(cornerRadius: AppTheme.tileRadius)
                    .fill(.quaternary)
                    .frame(width: 120, height: 74)
                    .overlay {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(((videos.first?.url.lastPathComponent ?? "") as NSString).deletingPathExtension)
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
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: AppTheme.largeCardRadius))
    }

    private func probeGrid(_ probe: ProbeResult) -> some View {
        let cols = [GridItem(.adaptive(minimum: 150), spacing: 10)]
        let cells: [(String, String, String)] = [
            ("Duration", SizeMath.durationLabel(probe.duration), "clock"),
            ("Resolution", "\(Int(probe.sourceSize.width))×\(Int(probe.sourceSize.height))", "aspect.ratio"),
            ("Frame rate", String(format: "%.0f fps", probe.nominalFPS), "speedometer"),
            ("Codec", probe.codecSubType, "cpu"),
            ("Audio", probe.hasAudio ? "✓ present" : "none", "waveform"),
            ("Color", probe.tags.humanLabel, "paintpalette"),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Source")
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
                    .background(Color.appTile, in: RoundedRectangle(cornerRadius: AppTheme.tileRadius))
                }
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Preset")

            if showingAllPresets || selectedPreset == nil {
                ForEach(availablePresets, id: \.id) { preset in
                    presetRow(preset)
                }
                Button {
                    withAnimation(.smooth) { showingAllPresets = false }
                } label: {
                    Label("Show fewer", systemImage: "chevron.up")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            } else if let selected = selectedPreset {
                // COLLAPSED: only the selected preset (with its live
                // numbers) + Change… — the estimate and Compress are above
                // the fold.
                PresetRow(preset: selected,
                          isSelected: true,
                          probe: singleProbe.map({ trimmed($0) }),
                          batchTotalBytes: isBatch ? totalBatchOutBytes(for: selected) : nil,
                          batchAvgBitrate: isBatch ? batchAvgBitrate(for: selected) : nil) { }
                    .contextMenu { presetContextMenu(selected) }
                Button {
                    withAnimation(.smooth) { showingAllPresets = true }
                } label: {
                    Label("Change…", systemImage: "slider.horizontal.3")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// One selectable preset row — shared by the collapsed and expanded
    /// states. The SELECTED row renders the live variant (lecture-mode
    /// tweaks mutate a copy with the same id) so its numbers match the
    /// estimate bar. Selecting collapses the list again.
    @ViewBuilder
    private func presetRow(_ preset: Preset) -> some View {
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
            showingAllPresets = false
        }
        .contextMenu { presetContextMenu(preset) }
    }

    /// Long-press actions for a preset row (extracted so the collapsed
    /// selected row offers the same Edit/Duplicate/Delete set).
    @ViewBuilder
    private func presetContextMenu(_ preset: Preset) -> some View {
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
            // Same agreement as totalBatchOutBytes: infeasible rows are
            // skipped by the batch gate — they must not dilute the average.
            guard plan.targetFeasible else { continue }
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
            let plan = QualitySizeOptimizer.plan(preset: preset, probe: p!)
            // AGREE WITH THE BATCH GATE in start(): infeasible rows are
            // SKIPPED (never enqueued), so the bar's total must not count
            // their unreachable outputs — "≈ X MB total" would include
            // videos the notice says weren't queued.
            guard plan.targetFeasible else { continue }
            total += plan.estimatedBytes
            valid += 1
        }
        return valid > 0 ? total : nil
    }

    private var estimate: OptimizerPlan? {
        guard let probe = singleProbe, let preset = selectedPreset else { return nil }
        return QualitySizeOptimizer.plan(preset: preset, probe: trimmed(probe))
    }

    /// TARGET-SIZE GATE (single video): the target the preset promises is
    /// physically unreachable for THIS clip's length (bitrate floor ×
    /// duration > target). The planner's correction passes can never close
    /// a gap that big, so the encode would run to completion — minutes per
    /// video — only to fail at verification. Gated BEFORE it runs instead:
    /// the button is disabled and the bar explains why.
    private var singleInfeasible: Bool {
        guard !isBatch, let plan = estimate else { return false }
        return !plan.targetFeasible
    }

    /// BATCH gate, complete form: every valid row is infeasible, so
    /// pressing Compress could not enqueue a single job — the button is
    /// disabled instead (the per-row "Too small for this length" text is
    /// the explanation). Partial batches stay enabled: the good rows go
    /// through and the skipped ones surface via the coordinator's notice.
    private var batchNothingStartable: Bool {
        guard isBatch, analysisDone, let preset = selectedPreset else { return false }
        let valid = probes.compactMap { $0 }
        guard !valid.isEmpty else { return false }
        return valid.allSatisfy {
            !QualitySizeOptimizer.plan(preset: preset, probe: $0).targetFeasible
        }
    }

    private var buttonTitle: String {
        if !analysisDone { return "Analyzing…" }
        guard selectedPreset != nil else { return "Choose a preset" }
        // The gate states itself: a greyed "Compress" that never explains
        // is the failure mode this round is fixing.
        if singleInfeasible || batchNothingStartable { return "Target too small" }
        return isBatch ? "Compress \(videos.count) videos" : "Compress"
    }

    private var canStart: Bool {
        guard analysisDone, selectedPreset != nil else { return false }
        return probes.contains { $0 != nil }
    }

    private func start() {
        guard let preset = selectedPreset, analysisDone else { return }
        // COUNT GUARD: probes and videos are indexed positionally below —
        // a rebuilt sheet presenting a different video count must never
        // reach a subscript (the reviewer's latent OOB; never observed on
        // device, but a one-line guard beats a crash).
        guard session.probes.count == videos.count else { return }
        // COMMIT GUARD: the enqueues below must happen exactly once for
        // this session — see didEnqueue (double tap = double batch).
        guard !didEnqueue else { return }
        didEnqueue = true
        // Commit-time truth for "last used": the preset that actually ran
        // (covers the lecture-mode variant too, which shares the base id).
        PresetStore.setLastUsedPreset(preset.id)
        // FEASIBILITY GATE: a target-size plan that can't fit the clip's
        // length (bitrate floor × duration > target) is not enqueued — its
        // encode would run to completion ONLY to fail at verification (the
        // planner floors the bitrate; no correction pass can close a gap
        // that big). Single videos are already blocked at the button
        // (singleInfeasible); in a BATCH one infeasible file must not hold
        // the other jobs hostage, so it is skipped with a notice instead.
        var skippedNames: [String] = []
        var enqueued = 0
        for i in videos.indices {
            guard let rawProbe = probes[i] else { continue }
            // Single video: plan against the TRIMMED window (estimates, the
            // target-size solve and the encode must all agree).
            let probe = isBatch ? rawProbe : trimmed(rawProbe)
            var plan = QualitySizeOptimizer.plan(preset: preset, probe: probe)
            if isBatch && !plan.targetFeasible {
                skippedNames.append(videos[i].url.lastPathComponent)
                continue
            }
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
            enqueued += 1
        }
        if !skippedNames.isEmpty {
            coordinator.skippedNotice = skippedNames.count == 1
                ? "“\(skippedNames[0])” wasn't queued: the selected target can't fit its length. Pick a larger target for it."
                : "\(skippedNames.count) videos weren't queued: the selected target can't fit their length. Pick a larger target for them."
        }
        // ALL rows infeasible (or none valid): stay in setup so the user can
        // pick a bigger target — closing the sheet now would read as a no-op
        // action and make the user hunt for rows that never appeared. The
        // guard RE-ARMS there: nothing was enqueued, so the next tap (with a
        // bigger preset) must be allowed to run.
        if enqueued > 0 {
            onDone()
        } else {
            didEnqueue = false
        }
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
        // SHELL-SWAP IDEMPOTENCE: the compact/regular threshold swap tears
        // this sheet down and re-presents it (.task re-fires) while the
        // RootView-owned session already holds this import's FULL analysis
        // — re-running would re-probe the entire batch and re-init the
        // trim window, discarding the user's adjustment. Same set + done →
        // nothing to do; a DIFFERENT set gets a fresh session.
        let keys = videos.map { $0.url.standardizedFileURL.path }
        if session.videoKeys == keys {
            guard !session.analysisDone else { return }
        } else {
            session.reset(for: videos)
        }
        // COUNT GUARD (latent OOB): writes below index probes by position —
        // sized by reset() above ONLY when keys differed. A stale-sized
        // array with fresh keys (the sheet re-evaluated with a different
        // videos array while the session survived) would write out of
        // bounds; size it honestly instead.
        if session.probes.count != videos.count {
            session.reset(for: videos)
        }
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

/// PHOTOS-STYLE TRIM STRIP: the filmstrip fills the row; the selected window
/// is outlined in yellow with two draggable end handles carrying live time
/// labels, everything outside is dimmed, and dragging the MIDDLE moves the
/// whole window with its length preserved — the same interaction model as
/// the Photos app trimmer. Replaces the old two-slider + nudge-button rows.
private struct TrimFilmstripPicker: View {
    /// One entry per requested SLOT (nil = that frame failed to grab and
    /// renders as a placeholder tile) — slot width stays `width / 8` no
    /// matter what, so the strip always matches the time grid.
    let frames: [UIImage?]
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    /// Fires while any drag is live (the setup flow stops the preview).
    var onDrag: (() -> Void)?

    private let handleWidth: CGFloat = 42
    private let minWindow: Double = 0.5

    /// Anchor for the whole-window move gesture (values when the drag began).
    @State private var moveAnchor: (Double, Double)?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let sx = start / max(duration, 0.1) * width
            let ex = end / max(duration, 0.1) * width
            ZStack(alignment: .leading) {
                filmstrip(width: width)
                // Dim OUTSIDE the window.
                HStack(spacing: 0) {
                    Rectangle().fill(.black.opacity(0.5))
                        .frame(width: max(0, sx))
                    Rectangle().fill(.clear)
                        .frame(width: max(0, ex - sx))
                    Rectangle().fill(.black.opacity(0.5))
                }
                // Yellow window outline.
                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, ex - sx))
                    .offset(x: sx)
                // Middle drag: move the whole window, length preserved.
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: max(0, ex - sx))
                    .offset(x: sx)
                    .gesture(moveGesture(width: width))
                handle(time: start, isStart: true, width: width)
                    .offset(x: max(0, min(width - handleWidth, sx - handleWidth / 2)))
                handle(time: end, isStart: false, width: width)
                    .offset(x: max(0, min(width - handleWidth, ex - handleWidth / 2)))
            }
            // Gestures read positions in the STRIP's space — the handles and
            // the window rect are offset views, so their own coordinate
            // spaces would return handle-local (wrong) locations.
            .coordinateSpace(.named("trimStrip"))
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.tileRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trim window")
        .accessibilityValue("From \(Self.timeString(start)) to \(Self.timeString(end))")
        // FOUR NAMED ACTIONS: the single adjustable action moved the WHOLE
        // window by ±1 s, so VoiceOver users could never set an edge.
        .accessibilityAction(named: "Start earlier") { start = max(0, start - 1) }
        .accessibilityAction(named: "Start later") { start = min(end - minWindow, start + 1) }
        .accessibilityAction(named: "End earlier") { end = max(start + minWindow, end - 1) }
        .accessibilityAction(named: "End later") { end = min(duration, end + 1) }
        .onDisappear { moveAnchor = nil }
    }

    @ViewBuilder
    private func filmstrip(width: CGFloat) -> some View {
        if frames.isEmpty {
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { _ in
                    Rectangle().fill(.quaternary)
                }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(frames.indices, id: \.self) { i in
                    Group {
                        if let img = frames[i] {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                    .frame(width: width / CGFloat(max(frames.count, 1)))
                    .clipped()
                }
            }
            .frame(width: width)
        }
    }

    /// Yellow end handle with the live time label — the Photos look.
    private func handle(time: Double, isStart: Bool, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(Self.timeString(time))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.black.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 3)
            Spacer(minLength: 0)
            VStack(spacing: 3) {
                Capsule().fill(.black.opacity(0.35)).frame(width: 14, height: 2)
                Capsule().fill(.black.opacity(0.35)).frame(width: 14, height: 2)
            }
            .padding(.bottom, 5)
        }
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity)
        .background(Color.yellow)
        .contentShape(Rectangle())
        .gesture(edgeGesture(isStart: isStart, width: width))
        .accessibilityHidden(true)
    }

    /// Edge drag: absolute placement in the strip's coordinate space.
    private func edgeGesture(isStart: Bool, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("trimStrip"))
            .onChanged { value in
                onDrag?()
                let t = value.location.x / width * duration
                if isStart {
                    start = max(0, min(t, end - minWindow))
                } else {
                    end = min(duration, max(t, start + minWindow))
                }
            }
            .onEnded { _ in moveAnchor = nil }
    }

    private func moveGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("trimStrip"))
            .onChanged { value in
                onDrag?()
                if moveAnchor == nil { moveAnchor = (start, end) }
                guard let anchor = moveAnchor else { return }
                let delta = value.translation.width / width * duration
                let len = anchor.1 - anchor.0
                var s = anchor.0 + delta
                s = max(0, min(s, duration - len))
                start = s
                end = s + len
            }
            .onEnded { _ in moveAnchor = nil }
    }

    static func timeString(_ s: Double) -> String {
        SizeMath.durationLabel(s)
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
                // MODERN radio glyph: `circle.inset.filled` is the selected-
                // state shape current Apple apps use (Reminders, Files).
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        // CODEC chip says what the file WILL BE: for a
                        // 10-bit/HDR probe the engine upgrades an H.264
                        // request to HEVC (plan.effectiveCodec carries the
                        // same decision offline). Without a probe (batch)
                        // per-source depth differs across the batch — the
                        // requested codec is then the only honest label.
                        let codecChip = probe.flatMap {
                            QualitySizeOptimizer.plan(preset: preset,
                                                      probe: $0).effectiveCodec
                        } ?? preset.codec
                        TagChip(text: codecChip == .hevc ? "HEVC" : "H.264")
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
            // Selected follows the APP TINT (accent) — a hard .blue ignored
            // the tint each preset row's chips/badges already use.
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.appCard,
                        in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
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
