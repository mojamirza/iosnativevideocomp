import SwiftUI
import Photos
import AVKit

/// The "compressing row": source info, live progress with cancel, error states
/// with retry, and the finished row with the output integrity report.
struct JobRowView: View, Equatable {
    let job: JobCoordinator.Job
    /// Passed in (not @EnvironmentObject) so the row can SKIP re-renders:
    /// an EnvironmentObject subscription re-rendered every card twice a
    /// second during encodes, which made the finished cards' ⋯ menus visibly
    /// “tick” on iPadOS 26. `==` compares everything the row renders —
    /// environment reads (size class) bypass == and still update.
    let coordinator: JobCoordinator
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingReport = false
    @State private var showingPlayer = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var saveNotice: String?
    // Existence cache: `FileManager.fileExists` ran inside body (render
    // paths) — synchronous disk I/O on EVERY frame the LazyVStack re-rendered
    // the row. Refreshed on appear and on state change instead.
    @State private var outputExists = false
    @State private var sourceExists = false

    private func refreshExistence() {
        if let out = job.outputURL {
            outputExists = FileManager.default.fileExists(atPath: out.path)
        } else {
            outputExists = false
        }
        sourceExists = FileManager.default.fileExists(atPath: job.sourceURL.path)
    }

    /// The row's title: for finished jobs, the OUTPUT's name (so renames
    /// are reflected); otherwise the source name.
    /// Batch-selection state (finished rows only — active jobs are transient
    /// and never selectable).
    private var inSelectionMode: Bool {
        coordinator.selectionMode && [.done, .failed, .cancelled].contains(job.state)
    }
    private var isSelectedRow: Bool {
        coordinator.selectedIDs.contains(job.id)
    }

    /// RENDER-SKIP (see the Job == docs): everything the row renders is
    /// derived from `job` plus these three coordinator values — a progress
    /// tick on ANOTHER job compares equal here and the card (and its ⋯
    /// menu) is left completely untouched. Actions are method calls on the
    /// shared coordinator instance, so skipping costs nothing.
    static func == (l: Self, r: Self) -> Bool {
        l.job == r.job
            && l.coordinator === r.coordinator
            && l.coordinator.selectionMode == r.coordinator.selectionMode
            && l.coordinator.selectedIDs.contains(l.job.id)
                == r.coordinator.selectedIDs.contains(r.job.id)
            // Queue-rank shifts (the “next up”/“#N in line” label) always
            // involve a job entering or leaving the queued set.
            && l.coordinator.jobs.filter { $0.state == .queued }.count
                == r.coordinator.jobs.filter { $0.state == .queued }.count
    }

    private var displayName: String {
        // FINISHED rows show the OUTPUT (renames reflected); everything
        // else the source. The extension is a FILE detail — display-only
        // stripping keeps rows (and rename prefill) clean.
        let base: String
        if job.state == .done, let out = job.outputURL {
            base = (out.lastPathComponent as NSString).deletingPathExtension
        } else {
            base = (job.sourceName as NSString).deletingPathExtension
        }
        // The machine STAMP the engine appends (`_custom-h264`,
        // `_high-quality-hevc`) is filename disambiguation, not a title the
        // user chose — drop everything from the last "_…codec" chunk in
        // DISPLAY only (the file on disk keeps its collision-proof name).
        if let stampRange = base.range(of: "_[^_]*?-(?:h264|hevc)$",
                                       options: .regularExpression) {
            return String(base[..<stampRange.lowerBound])
        }
        return base
    }

    var body: some View {
        // Swipe-to-delete comes from the HOSTING LIST now (native
        // swipeActions attached per row in RootView) — platform-grade
        // scroll/swipe resolution instead of a DragGesture bolted onto
        // scroll content, which kept fighting the scroll recognizer.
        // Destructive intents arm the root-level confirmation.
        rowBody
    }

    /// The row WITHOUT its modifier chain — kept a separate expression so the
    /// whole row (chain included) stays under the type-checker's complexity
    /// budget; combining everything into one expression stalled type-checking.
    private var baseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if inSelectionMode {
                    Button {
                        coordinator.toggleSelection(job.id)
                    } label: {
                        Image(systemName: isSelectedRow ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelectedRow ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelectedRow ? "Deselect" : "Select")
                }
                thumbnail
                titleBlock
                Spacer()
                if !inSelectionMode {
                    actionButtons
                }
            }

            stateSection

            if let msg = job.errorMessage {
                Label(msg, systemImage: "exclamationmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if job.state == .compressing,
               let started = job.startedAt, let plan = job.plan {
                // Alive-proof line: speed against realtime + honest ETA,
                // recomputed every second from REAL elapsed time.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    etaLabel(started: started, plan: plan)
                }
            }

            if job.state == .done && !inSelectionMode,
               // Legacy records can carry no report — showing the size line
               // would render "0 bytes → 0 bytes −0%" as if it were real.
               job.report != nil {
                reportRow
            }
        }
        .padding(14)
        .background(Color.appCard,
                    in: RoundedRectangle(cornerRadius: AppTheme.largeCardRadius))
        // SELECTION TAP (selection mode only): a permanent contentShape +
        // tap gesture on row content can interfere with swipe/scroll
        // gestures, so the full-row hit shape exists ONLY while selection
        // mode is on. The card background makes the whole card hit-testable
        // otherwise. See SelectionTapModifier below.
        .modifier(SelectionTapModifier(active: inSelectionMode) {
            coordinator.toggleSelection(job.id)
        })
        // VoiceOver container: composed summary first, controls stay
        // individually reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(a11ySummary)
        // HIG: rich content gets a long-press context menu mirroring the ⋯
        // actions (like Files / Photos rows) — SUPPRESSED during selection
        // (native multi-select behavior; the menu also routed destructive
        // actions exactly when the rows are acting as checkmarks).
        .modifier(SelectionContextMenuModifier(active: inSelectionMode) {
            contextMenuItems
        })
    }

    private var rowBody: some View {
        baseCard
            // Destructive confirmations present from the ROOT LIST
            // (RootView, pendingDeleteID/pendingCancelID) — NOT from the
            // row: destructive dialogs are always armed via requestDelete /
            // requestCancel, never executed directly from a row gesture.
        .sheet(isPresented: $showingReport) {
            if let report = job.report {
                ReportSheet(job: job, report: report)
            }
        }
        .sheet(isPresented: $showingPlayer) {
            OutputPlayerSheet(job: job)
        }
        .alert("Rename video", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                coordinator.renameOutput(jobID: job.id, to: renameText)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file in the app folder will be renamed.")
        }
        .alert("Save to Photos", isPresented: Binding(
            get: { saveNotice != nil },
            set: { if !$0 { saveNotice = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveNotice ?? "")
        }
        // Existence cache refresh: files can vanish (Files-app deletions) or
        // appear (Keep-anyway promotion) between renders without rebuilding
        // identity.
        .onAppear {
            refreshExistence()
            // History rows come back thumbnail-less after a relaunch (UIImage
            // bytes aren't persisted in SwiftData) — regenerate lazily.
            coordinator.ensureThumbnail(jobID: job.id)
        }
        .onChange(of: job.state) { _, _ in
            refreshExistence()
        }
        // A rename MOVES the output file: the cached existence flags must
        // re-check against the new path (stale flags made the row offer
        // actions against a path that no longer exists).
        .onChange(of: job.outputURL) { _, _ in
            refreshExistence()
        }
        // RETURNING FROM FILES (Split View / windowed multitasking): the
        // app folder is user-visible in Files, so deleting an output there
        // does NOT touch this row — no .appear, no state change, no URL
        // change — and Rename/Share/Save stayed enabled against a deleted
        // file (Rename's move then failed silently: the coordinator leaves
        // the file untouched on a throw, by design). Scene ACTIVATION is
        // the one moment "something below us may have changed": re-check.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshExistence()
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayName)
                // NATIVE list typography: body-size title, footnote metadata
                // (the Files / Podcasts row hierarchy).
                .font(.body.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(job.preset.name)
                    .font(.footnote)
                    .lineLimit(1)
                // ACTIVE states drop the status word here: the detail line
                // right below the title already says it ("Encoding… 5%",
                // "Queued — #2 in line") — "Custom · Queued" + "Queued · #2
                // in line" read the same fact twice. Done/failed/cancelled
                // keep it: those rows have nothing below.
                if ![.queued, .analyzing, .compressing, .verifying].contains(job.state) {
                    Text("·").font(.footnote)
                    Text(stateLabel)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(stateColor)
                }
            }
            .foregroundStyle(.secondary)
            // HISTORY meta line: thin rows gave no date/resolution/codec —
            // the three things "what did I make, when, how" wants. Date is
            // the job's start.
            if job.state == .done {
                Text("\(job.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(job.preset.resolution.displayName) · \(job.preset.codec.displayName)")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Compressed \(job.createdAt.formatted(date: .abbreviated, time: .shortened)), output \(job.preset.resolution.displayName), \(job.preset.codec.displayName)")
            }
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch job.state {
        case .compressing:
            ProgressView(value: job.progress) {
                HStack {
                    Text("\(job.passLabel ?? "Encoding…") \(Int(job.progress * 100))%")
                        .font(.footnote)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        // contentTransition only plays INSIDE an animation
                        // context — without this the digits hard-snap.
                        .animation(.default, value: job.progress)
                    Spacer()
                }
            }
            .tint(Color.accentColor)
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying output integrity…")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        case .queued:
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.footnote)
                Text(queuePositionLabel).font(.footnote)
            }
            .foregroundStyle(.secondary)
        case .analyzing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Analyzing source…")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// Tappable result line: the GREEN SAVINGS PILL LEADS (the row's
    /// headline number), sizes follow as secondary text, and the verdict
    /// icon is its own VoiceOver element. Replaces the struck-through,
    /// size-first line.
    private var reportRow: some View {
        Button {
            showingReport = true
        } label: {
            HStack(spacing: 8) {
                verdictIcon
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(verdictLabel)
                savingsPill
                inOutSizeTexts
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var verdictIcon: some View {
        // Three-state verdict: warnings (timed-out checks, inconclusive
        // decode) are NOT a green pass.
        switch job.report?.status {
        case .verified: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .warnings: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        default: EmptyView()
        }
    }

    private var verdictLabel: String {
        switch job.report?.status {
        case .verified: return "Verified"
        case .warnings: return "Passed with warnings"
        case .failed: return "Failed"
        default: return ""
        }
    }

    /// “−62%” green / “+8%” orange — SizeMath.deltaLabel keeps growth
    /// visible and never prints a lying “−0%”.
    private var savingsPill: some View {
        let grew = job.report?.grew ?? false
        let color: Color = grew ? .orange : .green
        return Text(SizeMath.deltaLabel(inBytes: job.report?.inBytes ?? 0,
                                        outBytes: job.report?.outBytes ?? 0))
            .font(.footnote.weight(.bold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(grew
                ? String(format: "%.0f percent larger", abs(job.report?.savingsPercent ?? 0))
                : String(format: "%.0f percent saved", max(0, job.report?.savingsPercent ?? 0)))
    }

    private var inOutSizeTexts: some View {
        let inText = ByteCountFormatter.string(fromByteCount: job.report?.inBytes ?? 0, countStyle: .file)
        let outText = ByteCountFormatter.string(fromByteCount: job.report?.outBytes ?? 0, countStyle: .file)
        return Text("\(inText) → \(outText)")
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input \(inText), output \(outText)")
    }

    /// The thumbnail doubles as the PLAY button: on finished rows a tap
    /// opens the output player (source/output toggle). While active, it's
    /// just an image so taps can't get lost mid-encode.
    @ViewBuilder
    private var thumbnail: some View {
        let isTerminal = [.done, .failed, .cancelled].contains(job.state)
        // Play affordance only when SOMETHING is still playable — a done job
        // whose output was deleted (and whose source import is gone) must
        // not open a dead sheet.
        let isPlayable = isTerminal && (outputExists || sourceExists)
        let image = Group {
            if let thumb = job.thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 74, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.thumbRadius))
            } else {
                RoundedRectangle(cornerRadius: AppTheme.thumbRadius)
                    .fill(.quaternary)
                    .frame(width: 74, height: 46)
                    .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
            }
        }
        if isPlayable && !inSelectionMode {
            Button {
                showingPlayer = true
            } label: {
                image
                    .overlay {
                        ZStack {
                            Circle().fill(.black.opacity(0.55))
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 0.5)
                        }
                        .frame(width: 22, height: 22)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play video")
        } else {
            image
        }
    }

    /// "2.3× realtime · about 4 min left" — elapsed time against progress.
    private func etaLabel(started: Date, plan: OptimizerPlan) -> some View {
        let elapsed = Date().timeIntervalSince(started)
        let p = max(0.001, job.progress)
        let encodedSeconds = Double(p) * plan.duration
        let speed = elapsed > 0.5 ? encodedSeconds / elapsed : 0
        let eta = p > 0.02 ? elapsed / p * (1 - p) : nil
        var parts: [String] = []
        if speed >= 0.2 {
            parts.append(String(format: "%.1f× realtime", speed))
        }
        if let eta, eta > 5 {
            let min = Int(eta.rounded()) / 60
            let sec = Int(eta.rounded()) % 60
            parts.append(min > 0 ? "about \(min) min \(sec) s left" : "about \(sec) s left")
        }
        guard !parts.isEmpty else {
            return AnyView(HStack(spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.footnote)
                Text("Encoding in progress…").font(.footnote)
            }
            .foregroundStyle(.secondary))
        }
        return AnyView(HStack(spacing: 6) {
            Image(systemName: "gauge.with.needle")
                .font(.footnote)
                .foregroundStyle(.tint)
            Text(parts.joined(separator: " · "))
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        })
    }

    /// Writes the compressed output straight into the user's photo library
    /// (add-only permission; no re-encode). Icon mirrors the native
    /// "Save Video" action as an SF symbol.
    private func saveToPhotos(_ url: URL) {
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveNotice = "Photos access was denied. Allow it in Settings → Privacy → Photos → Add Photos Only."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                saveNotice = "Saved to Photos."
            } catch {
                if !(error is CancellationError) {
                    saveNotice = "Couldn't save to Photos: \(error.localizedDescription)"
                }
            }
        }
    }

    /// "Queued · next up" / "Queued · #3 in line" — workers pick the OLDEST
    /// queued job first, so the position ranks by creation date.
    private var queuePositionLabel: String {
        guard job.state == .queued else { return "Queued" }
        let queued = coordinator.jobs.filter { $0.state == .queued }
            .sorted { $0.createdAt < $1.createdAt }
        guard let rank = queued.firstIndex(where: { $0.id == job.id }) else {
            return "Queued"
        }
        return rank == 0 ? "Queued · next up" : "Queued · #\(rank + 1) in line"
    }

    /// Container label for VoiceOver: a composed summary is announced before
    /// the (still individually reachable) row controls — children: .combine
    /// would hide the action buttons.
    private var a11ySummary: String {
        switch job.state {
        case .compressing:
            return "Compressing \(job.sourceName), \(Int(job.progress * 100)) percent, \(job.preset.name) preset"
        case .queued:
            return "\(job.sourceName), \(queuePositionLabel)"
        case .verifying:
            return "\(job.sourceName), verifying output integrity"
        case .done:
            return "Done: \(displayName), \(job.preset.name) preset"
        case .failed:
            return "Failed: \(displayName)\(job.errorMessage.map { ", \($0)" } ?? "")"
        case .cancelled:
            return "Cancelled: \(displayName)"
        case .analyzing:
            return "\(job.sourceName), analyzing source"
        }
    }

    private var stateLabel: String {
        switch job.state {
        case .queued: return "Queued"
        case .analyzing: return "Analyzing…"
        case .compressing: return "Compressing"
        case .verifying: return "Verifying…"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .orange
        default: return .secondary
        }
    }

    /// NATIVE row actions: plain SF Symbol icon buttons with 44 pt targets —
    /// the exact pattern Files/Messages use for row-level actions. Labels
    /// live in the accessibility layer and the context menu.
    private func iconButton(_ systemName: String, tint: Color,
                            a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 0) {
            switch job.state {
            case .queued, .analyzing, .compressing, .verifying:
                // Active jobs: just the cancel button — nothing else.
                iconButton("xmark.circle.fill", tint: .red,
                           a11y: "Cancel compression") { coordinator.requestCancel(jobID: job.id) }

            case .failed:
                if sourceExists {
                    iconButton("arrow.clockwise", tint: .accentColor,
                               a11y: "Retry") { coordinator.retry(jobID: job.id) }
                }
                ellipsisMenu

            case .cancelled:
                // Legacy state (only old history records can carry it — new
                // cancels remove the row entirely). Keep the menu actions.
                if sourceExists {
                    iconButton("arrow.clockwise", tint: .accentColor,
                               a11y: "Retry") { coordinator.retry(jobID: job.id) }
                }
                ellipsisMenu

            case .done:
                // The next actions people actually take — share it or put
                // it in Photos — live right on the row. Narrow widths drop
                // them: save+share+⋯ (132 pt) beside a 74 pt thumbnail
                // starves the title (device report, 1/3 Split View) — the
                // same actions live in the ⋯ menu and the context menu.
                if hSizeClass != .compact, let out = job.outputURL, outputExists {
                    iconButton("square.and.arrow.down", tint: .accentColor,
                               a11y: "Save to Photos") { saveToPhotos(out) }

                    ShareLink(item: out) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Share")
                }
                ellipsisMenu
            }
        }
    }

    private var ellipsisMenu: some View {
        Menu {
            contextMenuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions")
    }

    /// The row's actions in ONE place — shared by the ⋯ menu and the
    /// long-press context menu (HIG: both should mirror each other).
    @ViewBuilder
    private var contextMenuItems: some View {
        if job.report != nil {
            Button {
                showingReport = true
            } label: {
                Label("Integrity report", systemImage: "checklist")
            }
        }
        if job.state == .done, let out = job.outputURL {
            // The app folder is user-visible in Files — the output can be
            // deleted out from under a row at any time. Dead actions are
            // replaced with an honest "file removed" entry.
            if outputExists {
                Button {
                    showingPlayer = true
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                ShareLink(item: out) { Label("Share output", systemImage: "square.and.arrow.up") }
                // One click → straight into the photo library. The icon
                // matches the native "Save Video" action.
                Button {
                    saveToPhotos(out)
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                Button {
                    renameText = displayName
                    showingRename = true
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            } else {
                Button {
                    saveNotice = "The compressed file is gone from the app folder (deleted in Files?) — delete this row to clean up."
                } label: {
                    Label("File removed", systemImage: "questionmark.square.dashed")
                }
            }
        }
        if [.failed, .cancelled].contains(job.state),
           // Sources of finished jobs are deleted (storage management) —
           // offer Retry only while the source still exists.
           sourceExists {
            Button("Retry") { coordinator.retry(jobID: job.id) }
        }
        if job.state == .failed,
           let out = job.outputURL,
           outputExists {
            // A verifier false positive must not cost the user a finished
            // encode: promote the (scratch) file to Documents and flip
            // the row to Done. The report stays attached.
            Button("Keep anyway") { coordinator.keepFailedOutput(jobID: job.id) }
        }
        Divider()
        Button("Remove from list…", role: .destructive) { coordinator.requestDelete(jobID: job.id) }
    }
}

// MARK: - Output Integrity Report sheet

struct ReportSheet: View {
    let job: JobCoordinator.Job
    let report: IntegrityReport
    @EnvironmentObject private var coordinator: JobCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    /// Passed checks start COLLAPSED — six green detail cards are noise;
    /// failures and warnings are expanded by default.
    @State private var showingPasses = false

    /// Issues (failures + warnings) in report order — shown expanded.
    private var issueItems: [ReportItem] {
        report.items.filter { $0.severity != .pass }
    }
    /// HARD failures only — the headline "N checks failed" previously counted
    /// warnings into it, which read as if the file was broken.
    private var failedItems: [ReportItem] {
        report.items.filter { $0.severity == .fail }
    }
    private var passItems: [ReportItem] {
        report.items.filter { $0.severity == .pass }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard

                    ForEach(issueItems) { itemView($0) }

                    if !passItems.isEmpty {
                        DisclosureGroup(isExpanded: $showingPasses) {
                            VStack(spacing: 10) {
                                ForEach(passItems) { itemView($0) }
                            }
                            .padding(.top, 8)
                        } label: {
                            Label("Passed checks (\(passItems.count))",
                                  systemImage: "checkmark.circle")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.appCard,
                                    in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
                    }

                    HStack {
                        Spacer()
                        Text("Generated automatically after every encode by the output integrity verifier.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                }
                .padding()
            }
            .background(Color.appScreen)
            .navigationTitle("Integrity report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let out = job.outputURL {
                        ShareLink(item: out) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    // Plain-text export — verification results get pasted into
                    // tickets; the sheet stays the visual source of truth.
                    ShareLink(item: reportText) {
                        Label("Share report", systemImage: "doc.text")
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Fat-finger protection for the destructive delete.
            .confirmationDialog(
                "Delete this output?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    dismiss()
                    // Delete after the sheet has started dismissing —
                    // removing the presenting row mid-sheet-animation
                    // can upset SwiftUI.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        coordinator.delete(jobID: job.id)
                    }
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("The compressed video and its history entry will be removed. This cannot be undone.")
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: ReportItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.severity.symbol)
                .foregroundStyle(color(item.severity))
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.appCard,
                    in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
    }

    /// Plain-text form of the report for sharing.
    private var reportText: String {
        var lines: [String] = []
        lines.append("VidCompress integrity report")
        lines.append("Source: \(job.sourceName) · Preset: \(job.preset.name)")
        let inS = ByteCountFormatter.string(fromByteCount: report.inBytes, countStyle: .file)
        let outS = ByteCountFormatter.string(fromByteCount: report.outBytes, countStyle: .file)
        let sign = report.grew ? "+" : "−"
        lines.append("Input \(inS) → Output \(outS) (\(sign)\(String(format: "%.0f", abs(report.savingsPercent)))%)")
        for item in report.items {
            let mark = item.severity == .pass ? "✓" : (item.severity == .warn ? "⚠" : "✗")
            lines.append("\(mark) \(item.title) — \(item.detail)")
        }
        return lines.joined(separator: "\n")
    }

    private var summaryCard: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        // Nil stats (verification timed out) display as "—", never "0".
        // flatMap end-guards Int(NaN) — which TRAPS — for any report decoded
        // before the init-side clamp existed. THE shared duration formatter:
        // long videos read h:mm:ss, encode time no longer prints "1834.25 s".
        let durationText = report.outputDuration
            .flatMap { $0.isFinite ? $0 : nil }
            .map { SizeMath.durationLabel($0) }
            ?? "—"
        let bitrateText = report.outputBitrateMbps.map { String(format: "%.1f Mbps", $0) } ?? "—"
        let savedText = report.grew
            ? String(format: "+%.0f%%", abs(report.savingsPercent))     // output grew
            : String(format: "%.0f%%", report.savingsPercent)
        let cells: [(String, String)] = [
            (ByteCountFormatter.string(fromByteCount: report.inBytes, countStyle: .file), "Input"),
            (ByteCountFormatter.string(fromByteCount: report.outBytes, countStyle: .file), "Output"),
            (savedText, report.grew ? "Grew by" : "Saved"),
            (SizeMath.durationLabel(report.encodeSeconds), "Encode time"),
            (durationText, "Duration"),
            (bitrateText, "Output bitrate"),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                switch report.status {
                case .verified:
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("\(passItems.count) checks passed").font(.headline)
                case .warnings:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text("\(passItems.count) of \(report.items.count) checks passed").font(.headline)
                case .failed:
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("\(failedItems.count) checks failed").font(.headline)
                }
            }
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(cells, id: \.1) { cell in
                    VStack(spacing: 2) {
                        Text(cell.0)
                            .font(.callout.weight(.bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(report.grew && cell.1 == "Grew by"
                                             ? Color.orange : .primary)
                        Text(cell.1)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Checks: ✓ pass · ⚠ worth a look · ✗ failed. A warning means something to review — not that the file is broken.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("Source: \(job.sourceName) · Preset: \(job.preset.name)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color.appCard,
                    in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
    }

    private func color(_ s: ReportSeverity) -> Color {
        switch s {
        case .pass: return .green
        case .warn: return Color.orange
        case .fail: return .red
        }
    }
}

// MARK: - Output player

/// In-app playback of the compressed result with a Source toggle for
/// side-by-side comparison at the SAME timestamp — quality claims become
/// checkable without leaving the app.
///
/// Graceful degradation matters here: done jobs delete the source import,
/// and any file can be removed by the user in Files, so the toggle only
/// appears when BOTH files still exist, and the sheet picks whichever
/// side is actually available.
private struct OutputPlayerSheet: View {
    @EnvironmentObject private var coordinator: JobCoordinator
    @Environment(\.dismiss) private var dismiss

    let job: JobCoordinator.Job

    // LAZY: the old eager `AVPlayer()` initialised a full player (plus its
    // CoreAudio/CMA timeouts) on every row the sheet was CREATED from, even
    // before `onAppear` decided which file even exists. Built on first load.
    @State private var player: AVPlayer?
    @State private var side: Side = .output
    @State private var sourceExists = false
    @State private var outputExists = false
    @State private var didLoad = false
    /// Display aspect of the CURRENT video (transform-applied). Nil until
    /// measured — the fixed 16/9 letterboxed portrait phone videos and 4:3
    /// clips badly.
    @State private var aspect: CGFloat?
    /// FIRST-FRAME PRIMING task — see primeThenPlay(_:at:). Playback starts
    /// only after the item has loaded its tracks (rotation transform
    /// included), so the first presented frame is never the un-rotated one.
    @State private var priming: Task<Void, Never>?

    enum Side: Hashable { case output, source }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if !outputExists && !sourceExists {
                    // Honest empty state instead of a dead black rectangle:
                    // done jobs delete the source import, and the output may
                    // have been removed in Files.
                    VStack(spacing: 10) {
                        Image(systemName: "questionmark.square.dashed")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("This video is gone")
                            .font(.headline)
                        Text("The compressed file and its source were both removed from the app's folders.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(aspect ?? 16.0 / 9.0, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
                        .padding(.horizontal, 16)
                        .accessibilityLabel("Video preview")
                } else {
                    RoundedRectangle(cornerRadius: AppTheme.cardRadius)
                        .fill(Color.black)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .padding(.horizontal, 16)
                        .overlay { ProgressView().tint(.white) }
                }

                // Compare toggle ONLY when both the output and the source
                // still exist (done jobs delete the source import).
                if outputExists && sourceExists {
                    Picker("Compare", selection: $side) {
                        Text("Output").tag(Side.output)
                        Text("Source").tag(Side.source)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    Text("Switching keeps the same playback position.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !outputExists && sourceExists {
                    Text("The compressed file is gone — showing the source instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.top, 12)
            .background(Color.appScreen)
            .navigationTitle(displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: load)
            .onDisappear(perform: teardown)
            // Source↔Output comparison keeps the same playback position.
            .onChange(of: side) { _, newSide in
                swapSide(new: newSide)
            }
        }
    }

    private var displayTitle: String {
        if job.state == .done, let out = job.outputURL {
            return (out.lastPathComponent as NSString).deletingPathExtension
        }
        return job.sourceName
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let out = job.outputURL
        // The real existence check — Job.outputURL can outlive its file.
        outputExists = out.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        sourceExists = FileManager.default.fileExists(atPath: job.sourceURL.path)
        // Default to the output; fall back to the source if it's gone.
        side = outputExists ? .output : .source
        // Audio session: VideoPlayer does not configure one itself, and with
        // the default .ambient category playback can be silenced by the
        // ringer switch and respects nothing else on the device.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let next = playerItem(for: side)
        let newPlayer = AVPlayer()
        newPlayer.replaceCurrentItem(with: next)
        player = newPlayer
        // PRIMED start (see primeThenPlay): never play an item whose tracks
        // are still loading — the first frame would render before the
        // track's rotation transform is applied.
        primeThenPlay(newPlayer, at: .zero)
        measureAspect(for: newPlayer.currentItem)
    }

    /// Measure the video's DISPLAY aspect (naturalSize with its track
    /// transform applied — portrait 4K stored as 3840×2160 is genuinely
    /// 9:16 on screen) instead of forcing every clip into 16:9.
    private func measureAspect(for item: AVPlayerItem?) {
        // ASYNC track load: the synchronous tracks(withMediaType:) is
        // deprecated since iOS 15 and can block on slow containers.
        Task { @MainActor in
            guard let tracks = try? await item?.asset.loadTracks(withMediaType: .video),
                  let track = tracks.first else { return }
            let size: CGSize? = try? await track.load(.naturalSize)
            let transform: CGAffineTransform? = try? await track.load(.preferredTransform)
            guard let size, size.width > 0, size.height > 0 else { return }
            let applied = size.applying(transform ?? .identity)
            let w = abs(applied.width), h = abs(applied.height)
            if w > 0, h > 0 { aspect = w / h }
        }
    }

    /// FIRST-FRAME PRIMING (the 180°-rotation flash): playing an item whose
    /// tracks are still loading lets the player layer present the very
    /// first decoded frame BEFORE the track's rotation transform has been
    /// applied — a video recorded upside down (180° transform) flashes
    /// rotated for one frame and then corrects. Wait for the item to be
    /// READY, seek to the start with ZERO tolerance (forces the renderer to
    /// decode the exact frame with the full track geometry), and only then
    /// start playback. While priming, the sheet shows the player's own
    /// black surface — no wrong-orientation frame ever hits the screen.
    private func primeThenPlay(_ player: AVPlayer, at start: CMTime) {
        priming?.cancel()
        guard let item = player.currentItem else { return }
        if item.status == .readyToPlay {
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            return
        }
        priming = Task { @MainActor in
            // Bounded wait (50 ms cadence, 10 s cap): a slow container must
            // not leave the sheet on a black surface forever — past the cap,
            // play whatever the player has (the previous behavior).
            var waitedNs = 0
            while item.status == .unknown, waitedNs < 10_000_000_000,
                  !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waitedNs += 50_000_000
            }
            guard !Task.isCancelled else { return }
            // await the seek: in an async context the call resolves to the
            // async overload anyway (CI round 42402881445), and awaiting it
            // is exactly the priming intent — playback starts only AFTER the
            // seek has landed on the exact frame with the full geometry.
            await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        }
    }

    /// Tear down the player and its audio session — a sheet that merely
    /// disappears previously left the session active, muting other audio.
    private func teardown() {
        priming?.cancel()
        priming = nil
        guard let player else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false,
                                                        options: .notifyOthersOnDeactivation)
    }

    private func playerItem(for side: Side) -> AVPlayerItem? {
        switch side {
        case .output:
            if outputExists, let out = job.outputURL {
                return AVPlayerItem(url: out)
            }
            return nil
        case .source:
            guard sourceExists else { return nil }
            return AVPlayerItem(url: job.sourceURL)
        }
    }

    /// Output t=0 == source (startOffset + trimStart) on trimmed jobs — the
    /// same mapping the verifier uses. Without translating the playhead,
    /// the Source/Output toggle showed a DIFFERENT scene on trimmed clips.
    private var compareOffset: Double {
        (job.plan?.trimStart ?? 0) + (job.plan?.source.startOffset ?? 0)
    }

    /// Swapping to compare preserves the playback position and continues
    /// playback — the two videos stay in lock-step on the SAME scene.
    private func swapSide(new: Side) {
        guard let player else { return }
        let time = player.currentTime()
        // A priming task in flight means playback was INTENDED but had not
        // started yet — keep that intent across the swap.
        let wasPlaying = player.rate > 0 || priming != nil
        // TRANSLATE: output timeline → source timeline (add the trim lead-in)
        // and back (clamp at zero — the output cannot show pre-trim content).
        let translated = new == .source
            ? time.seconds + compareOffset
            : max(0, time.seconds - compareOffset)
        let seekTarget = CMTime(seconds: translated, preferredTimescale: 600)
        let next = playerItem(for: new)
        player.replaceCurrentItem(with: next)
        if wasPlaying {
            // The compressed runtime can differ slightly (fps cap), but
            // AVPlayer clamps the seek itself. PRIMED start on the fresh
            // item — same first-frame rule as load().
            primeThenPlay(player, at: translated > 0 ? seekTarget : .zero)
        } else if translated > 0 {
            // Paused stays paused — but still settle the geometry so the
            // paused frame shows correctly oriented on the new side.
            player.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        measureAspect(for: next)
    }
}

/// Full-row tap target for BATCH SELECTION, active only while selection
/// mode is on: .contentShape(Rectangle()) + tap make the whole row
/// (trailing spacer included) toggle the checkmark — the pre-List bug this
/// first fixed. Permanent row-wide shapes/gestures interfere with the
/// List's native swipe gestures, so normal-mode rows get NONE of this.
private struct SelectionTapModifier: ViewModifier {
    let active: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if active {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
        } else {
            content
        }
    }
}

/// Long-press context menus are OFF while selection mode is on — the native
/// Photos/Files pattern (tapping long just selects there too) and the
/// blocking factor for the menu's destructive items firing mid-selection.
private struct SelectionContextMenuModifier<Items: View>: ViewModifier {
    let active: Bool
    let items: () -> Items

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content
        } else {
            content.contextMenu { items() }
        }
    }
}
