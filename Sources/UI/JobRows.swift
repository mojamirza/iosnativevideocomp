import SwiftUI

/// The "compressing row": source info, live progress with cancel, error states
/// with retry, and the finished row with the output integrity report.
struct JobRowView: View {
    @EnvironmentObject private var coordinator: JobCoordinator

    let job: JobCoordinator.Job
    @State private var showingReport = false

    var body: some View {
        // Finished rows can be swiped sideways to reveal Delete; active
        // (queued/encoding) rows can't.
        if [.done, .failed, .cancelled].contains(job.state) {
            rowBody
                .modifier(SwipeToDeleteModifier { coordinator.delete(jobID: job.id) })
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
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

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.sourceName)
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
                Spacer()
                actionButtons
            }

            if job.state == .compressing {
                ProgressView(value: job.progress) {
                    HStack {
                        Text("Encoding… \(Int(job.progress * 100))%")
                            .font(.caption2)
                            .monospacedDigit()
                        Spacer()
                    }
                }
                .tint(.green)
            } else if job.state == .verifying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Verifying output integrity…")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            } else if job.state == .queued {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.caption2)
                    Text("Queued").font(.caption2)
                }
                .foregroundStyle(.tertiary)
            } else if job.state == .analyzing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Analysing frames with Core Image…")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }

            if let msg = job.errorMessage {
                Label(msg, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if job.state == .done, let report = job.report {
                Button {
                    showingReport = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: report.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(report.passed ? .green : .red)
                        Text(ByteCountFormatter.string(fromByteCount: job.report?.inBytes ?? 0, countStyle: .file))
                            .strikethrough()
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(ByteCountFormatter.string(fromByteCount: job.report?.outBytes ?? 0, countStyle: .file))
                            .font(.caption.weight(.bold))
                        Text(String(format: "−%.0f%%", report.savingsPercent))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showingReport) {
            if let report = job.report {
                ReportSheet(job: job, report: report)
            }
        }
    }

    private var stateLabel: String {
        switch job.state {
        case .queued: return "Queued"
        case .analyzing: return "Analysing…"
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
                    coordinator.cancel(jobID: job.id)
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
                // Just the three-dot menu: report, share, and delete all live
                // there.
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
                ShareLink(item: out) { Label("Share output", systemImage: "square.and.arrow.up") }
            }
            if [.failed, .cancelled].contains(job.state),
               // Sources of finished jobs are deleted (storage management) —
               // offer Retry only while the source still exists.
               FileManager.default.fileExists(atPath: job.sourceURL.path) {
                Button("Retry") { coordinator.retry(jobID: job.id) }
            }
            Divider()
            Button("Remove from list", role: .destructive) { coordinator.delete(jobID: job.id) }
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

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                offsetX = 0
                            }
                            onDelete()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "trash.fill").font(.body)
                                Text("Delete").font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(width: revealWidth - 12, height: geo.size.height - 12)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                    // The card itself is offset below — which would drag its
                    // background (and this button) along. Counter-offsetting
                    // the background cancels that out, so the button STAYS at
                    // the trailing edge and gets revealed as the card slides
                    // away to the left.
                    .offset(x: -offsetX)
                }
            )
            .offset(x: offsetX)
            .simultaneousGesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 25)
            .onChanged { value in
                // Horizontal-dominant drags only — vertical ones belong to
                // the list's ScrollView.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if dragStart == nil { dragStart = offsetX }
                let target = dragStart! + value.translation.width
                offsetX = min(0, max(-revealWidth, target))
            }
            .onEnded { value in
                defer { dragStart = nil }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    offsetX = offsetX < -revealWidth / 2 ? -revealWidth : 0
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard

                    ForEach(report.items) { item in
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
                                    .lineLimit(4)
                            }
                            Spacer()
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
                    Button(role: .destructive) {
                        dismiss()
                        // Delete after the sheet has started dismissing —
                        // removing the presenting row mid-sheet-animation
                        // can upset SwiftUI.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            coordinator.delete(jobID: job.id)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var summaryCard: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        let cells: [(String, String)] = [
            (ByteCountFormatter.string(fromByteCount: report.inBytes, countStyle: .file), "Input"),
            (ByteCountFormatter.string(fromByteCount: report.outBytes, countStyle: .file), "Output"),
            (String(format: "%.0f%%", report.savingsPercent), "Saved"),
            (String(format: "%.2f s", report.encodeSeconds), "Encode time"),
            (String(format: "%d:%02d", Int(report.outputDuration) / 60, Int(report.outputDuration) % 60), "Duration"),
            (String(format: "%.1f Mbps", report.outputBitrateMbps), "Output bitrate"),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: report.passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(report.passed ? .green : .red)
                Text(report.passed ? "All integrity checks passed" : "Integrity issues found")
                    .font(.headline)
            }
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(cells, id: \.1) { cell in
                    VStack(spacing: 2) {
                        Text(cell.0)
                            .font(.callout.weight(.bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(cell.1)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
