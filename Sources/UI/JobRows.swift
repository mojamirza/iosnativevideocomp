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
    @State private var confirmingCancel = false
    @State private var confirmingDelete = false
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
        // Finished rows can be swiped sideways to reveal Delete; active
        // (queued/encoding) rows can't. Swiping is disabled during batch
        // selection (taps toggle selection instead).
        if [.done, .failed, .cancelled].contains(job.state), !inSelectionMode {
            rowBody
                .modifier(SwipeToDeleteModifier { confirmingDelete = true })
        } else {
            rowBody
        }
    }

    /// The card WITHOUT modifier chain — kept a separate expression so the
    /// whole row (chain included) stays under the type-checker's complexity
    /// budget; combining everything into one expression stalled type-checking.
    private var baseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
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
                    .font(.caption)
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

            if job.state == .done && !inSelectionMode {
                reportRow
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        // VoiceOver container: composed summary first, controls stay
        // individually reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(a11ySummary)
        // Batch selection: tapping anywhere toggles the row.
        .onTapGesture {
            if inSelectionMode {
                coordinator.toggleSelection(job.id)
            }
        }
    }

    private var rowBody: some View {
        baseCard
        // Fat-finger protection for destructive actions.
        .confirmationDialog(
            job.state == .queued ? "Remove from queue?" : "Stop this compression?",
            isPresented: $confirmingCancel,
            titleVisibility: .visible) {
            Button(job.state == .queued ? "Remove from queue" : "Stop & discard",
                   role: .destructive) {
                coordinator.cancel(jobID: job.id)
            }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text(job.state == .queued
                 ? "The queued job will be removed from the list."
                 : "Encoding progress will be lost and the partial file deleted.")
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                coordinator.delete(jobID: job.id)
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The compressed video and its history entry will be removed. This cannot be undone.")
        }
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
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(job.preset.name)
                    .font(.caption2)
                    .lineLimit(1)
                Text("·").font(.caption2)
                Text(stateLabel)
                    .font(.caption2.weight(.semibold))
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
                        .font(.caption2)
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
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        case .queued:
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.caption2)
                Text(queuePositionLabel).font(.caption2)
            }
            .foregroundStyle(.tertiary)
        case .analyzing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Analyzing source…")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
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
                        .foregroundStyle(Color(UIColor.systemOrange))
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
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(ByteCountFormatter.string(fromByteCount: report?.outBytes ?? 0, countStyle: .file))
                .font(.caption.weight(.bold))
            if report?.grew == true {
                // Negative savings (output LARGER than source) must be
                // visible, not rounded to 0%.
                Text(String(format: "+%.0f%%", abs(report?.savingsPercent ?? 0)))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(UIColor.systemOrange))
            } else {
                Text(String(format: "−%.0f%%", report?.savingsPercent ?? 0))
                    .font(.caption.weight(.bold))
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
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
                    .font(.caption2)
                Text("Encoding in progress…").font(.caption2)
            }
            .foregroundStyle(.tertiary))
        }
        return AnyView(HStack(spacing: 6) {
            Image(systemName: "gauge.with.needle")
                .font(.caption2)
                .foregroundStyle(.tint)
            Text(parts.joined(separator: " · "))
                .font(.caption2.weight(.medium))
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
        case .cancelled: return Color(UIColor.systemOrange)
        default: return Color(UIColor.systemGray)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .queued, .analyzing, .compressing, .verifying:
                // Active jobs: just the cancel button — nothing else.
                Button {
                    confirmingCancel = true
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)

            case .failed:
                Button {
                    coordinator.retry(jobID: job.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.tint.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                ellipsisMenu

            case .cancelled:
                // Legacy state (only old history records can carry it — new
                // cancels remove the row entirely). Keep the menu actions.
                Button {
                    coordinator.retry(jobID: job.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.tint.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                ellipsisMenu

            case .done:
                // The next actions people actually take — share it or put
                // it in Photos — live right on the row; Rename, Report and
                // Remove stay in the menu.
                if let out = job.outputURL, outputExists {
                    Button {
                        saveToPhotos(out)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save to Photos")

                    ShareLink(item: out) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }
                    .accessibilityLabel("Share")
                }
                ellipsisMenu
            }
        }
    }

    private var ellipsisMenu: some View {
        Menu {
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
            Button("Remove from list…", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

/// Swipe-to-delete for finished rows: dragging the row left reveals a red
/// Delete button behind its trailing edge. Only horizontal-dominant drags
/// move the row, so vertical scrolling of the list keeps working.
private struct SwipeToDeleteModifier: ViewModifier {
    let onDelete: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var dragStart: CGFloat?

    private let revealWidth: CGFloat = 92

    /// Respect Reduce Motion: snap without springing.
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Whether the delete button is fully revealed (row at max offset).
    private var revealed: Bool { offsetX <= -revealWidth + 2 }

    func body(content: Content) -> some View {
        content
            // Offset FIRST: the transform wraps only the card. Then the
            // overlay is layered on OUTSIDE that transform, so it stays
            // pinned at the row's un-shifted trailing edge while the card
            // slides left to reveal it. The previous counter-offset-
            // background approach made the revealed button drift/glide
            // instead of appearing crisply in place.
            .offset(x: offsetX)
            .overlay(alignment: .trailing) {
                deleteButton
                    .opacity(revealed ? 1 : 0)
                    .allowsHitTesting(revealed)
            }
            .simultaneousGesture(dragGesture)
    }

    private var deleteButton: some View {
        Button {
            // Snap the row shut while the confirmation dialog appears.
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                offsetX = 0
            }
            onDelete()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "trash.fill").font(.body)
                Text("Delete").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: revealWidth - 14)
            .frame(maxHeight: .infinity)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
    }

    private var dragGesture: some Gesture {
        // Short arming distance — a long one made the first stretch of the
        // drag feel dead, which reads as "laggy" even when tracking cleanly.
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Anchor the drag start on the FIRST change regardless of
                // direction — anchoring late (only once horizontal-dominant)
                // made the row jump instead of tracking the finger.
                if dragStart == nil { dragStart = offsetX }
                // Horizontal-dominant drags only — vertical ones belong to
                // the list's ScrollView.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let raw = dragStart! + value.translation.width
                // Rubber-band past the reveal point (soft clamp) and stop
                // hard at zero; the row moves with the finger, unanimated.
                let target: CGFloat
                if raw < -revealWidth {
                    target = -revealWidth + (raw + revealWidth) * 0.15
                } else {
                    target = min(0, raw)
                }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    offsetX = max(-revealWidth - 24, target)
                }
            }
            .onEnded { value in
                defer { dragStart = nil }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // A quick flick opens fully even on a short drag; a slow
                // drag needs to pass half the reveal width.
                let flick = value.velocity.width < -900
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)) {
                    offsetX = (flick || offsetX < -revealWidth / 2) ? -revealWidth : 0
                }
            }
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
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12))
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
            .background(Color(.systemGroupedBackground))
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
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
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
                        .foregroundStyle(Color(UIColor.systemOrange))
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
                                             ? Color(UIColor.systemOrange) : .primary)
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
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func color(_ s: ReportSeverity) -> Color {
        switch s {
        case .pass: return .green
        case .warn: return Color(UIColor.systemOrange)
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
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                        .accessibilityLabel("Video preview")
                } else {
                    RoundedRectangle(cornerRadius: 12)
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
            .background(Color(.systemGroupedBackground))
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
        newPlayer.play()
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

    /// Tear down the player and its audio session — a sheet that merely
    /// disappears previously left the session active, muting other audio.
    private func teardown() {
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
        let wasPlaying = player.rate > 0
        let next = playerItem(for: new)
        player.replaceCurrentItem(with: next)
        if time.seconds > 0 {
            // The compressed runtime can differ slightly (fps cap), but
            // AVPlayer clamps the seek itself.
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if wasPlaying { player.play() }
        measureAspect(for: next)
    }
}
