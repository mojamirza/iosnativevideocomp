import SwiftUI
import Photos
import AVKit

/// The "compressing row": source info, live progress with cancel, error states
/// with retry, and the finished row with the output integrity report.
struct JobRowView: View {
    @EnvironmentObject private var coordinator: JobCoordinator

    let job: JobCoordinator.Job
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

    private var displayName: String {
        if job.state == .done, let out = job.outputURL {
            return (out.lastPathComponent as NSString).deletingPathExtension
        }
        return job.sourceName
    }

    var body: some View {
        // The row is a NATIVE List row: swipe actions and the context menu
        // come from the framework (the hand-rolled swipe-to-delete modifier
        // is gone). Batch-selection taps still toggle the row.
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
        .padding(.vertical, 4)
        // SELECTION TAP (selection mode only): a permanent contentShape +
        // tap gesture on row content interferes with the List's native
        // swipe gestures (device report: swiped rows behaved "weird"), so
        // the full-row hit shape exists ONLY while selection mode is on —
        // where swipes are disabled anyway. Normal-mode rows keep their
        // swipe/column gestures untouched. See SelectionTapModifier below.
        .modifier(SelectionTapModifier(active: inSelectionMode) {
            coordinator.toggleSelection(job.id)
        })
        // VoiceOver container: composed summary first, controls stay
        // individually reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(a11ySummary)
        // HIG: rich content gets a long-press context menu mirroring the ⋯
        // actions (like Files / Photos rows).
        .contextMenu { contextMenuItems }
    }

    private var rowBody: some View {
        baseCard
            // NATIVE swipe actions (List rows) — trailing: Delete on finished
            // rows, Stop on active ones; leading: Retry where it applies.
            // Hidden during batch selection (taps toggle selection there).
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !inSelectionMode {
                    if [.done, .failed, .cancelled].contains(job.state) {
                        Button(role: .destructive) {
                            // ARM ONLY — the confirmation dialog presents
                            // from the ROOT LIST (RootView), not from this
                            // mid-swipe row: in-row dialogs are not reliably
                            // anchored on iPadOS 26 and silently skipped
                            // the fat-finger step (device report).
                            coordinator.requestDelete(jobID: job.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } else {
                        Button(role: .destructive) {
                            coordinator.requestCancel(jobID: job.id)
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if !inSelectionMode,
                   [.failed, .cancelled].contains(job.state),
                   sourceExists {
                    Button {
                        coordinator.retry(jobID: job.id)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .tint(.accentColor)
                }
            }
            // Fat-finger confirmations for destructive actions present from
            // the ROOT LIST (RootView, pendingDeleteID/pendingCancelID) —
            // NOT from the row: in-row dialogs were silently skipped on
            // device. Nothing dialog-related is attached here anymore.
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
                Text("·").font(.footnote)
                Text(stateLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(stateColor)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch job.state {
        case .compressing:
            ProgressView(value: job.progress) {
                HStack {
                    Text("Encoding… \(Int(job.progress * 100))%")
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

    /// Tappable in/out size line with the three-state verdict icon.
    private var reportRow: some View {
        Button {
            showingReport = true
        } label: {
            HStack(spacing: 8) {
                // Three-state verdict: warnings (timed-out checks,
                // inconclusive decode) are NOT a green pass.
                switch job.report?.status {
                case .verified:
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                case .warnings:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                case .failed:
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                default:
                    EmptyView()
                }
                inOutSizeTexts
            }
        }
        .buttonStyle(.plain)
    }

    private var inOutSizeTexts: some View {
        HStack(spacing: 8) {
            let report = job.report
            Text(ByteCountFormatter.string(fromByteCount: report?.inBytes ?? 0, countStyle: .file))
                .strikethrough(!(report?.grew ?? false))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Text(ByteCountFormatter.string(fromByteCount: report?.outBytes ?? 0, countStyle: .file))
                .font(.footnote.weight(.bold))
            if report?.grew == true {
                // Negative savings (output LARGER than source) must be
                // visible, not rounded to 0%.
                Text(String(format: "+%.0f%%", abs(report?.savingsPercent ?? 0)))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.orange)
            } else {
                Text(String(format: "−%.0f%%", report?.savingsPercent ?? 0))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.green)
            }
        }
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
                // it in Photos — live right on the row; Rename, Report and
                // Remove stay in the context menu.
                if let out = job.outputURL, outputExists {
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
        // before the init-side clamp existed.
        let durationText = report.outputDuration
            .flatMap { $0.isFinite ? $0 : nil }
            .map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) }
            ?? "—"
        let bitrateText = report.outputBitrateMbps.map { String(format: "%.1f Mbps", $0) } ?? "—"
        let savedText = report.grew
            ? String(format: "+%.0f%%", abs(report.savingsPercent))     // output grew
            : String(format: "%.0f%%", report.savingsPercent)
        let cells: [(String, String)] = [
            (ByteCountFormatter.string(fromByteCount: report.inBytes, countStyle: .file), "Input"),
            (ByteCountFormatter.string(fromByteCount: report.outBytes, countStyle: .file), "Output"),
            (savedText, report.grew ? "Grew by" : "Saved"),
            (String(format: "%.2f s", report.encodeSeconds), "Encode time"),
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

    /// Swapping to compare preserves the playback position and continues
    /// playback — the two videos stay in lock-step on the same frame.
    private func swapSide(new: Side) {
        guard let player else { return }
        let time = player.currentTime()
        // A priming task in flight means playback was INTENDED but had not
        // started yet — keep that intent across the swap.
        let wasPlaying = player.rate > 0 || priming != nil
        let next = playerItem(for: new)
        player.replaceCurrentItem(with: next)
        if wasPlaying {
            // The compressed runtime can differ slightly (fps cap), but
            // AVPlayer clamps the seek itself. PRIMED start on the fresh
            // item — same first-frame rule as load().
            primeThenPlay(player, at: time.seconds > 0 ? time : .zero)
        } else if time.seconds > 0 {
            // Paused stays paused — but still settle the geometry so the
            // paused frame shows correctly oriented on the new side.
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
