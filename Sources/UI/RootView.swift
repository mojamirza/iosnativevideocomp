import SwiftUI
import PhotosUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

// Root screen: pillar banner + list of compression jobs,
// with the "compressing row" (progress + cancel + error + report).

struct RootView: View {
    @EnvironmentObject private var coordinator: JobCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingSetup = false
    @State private var importedVideos: [PickedVideo] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var importError: String?
    @State private var dropActive = false
    @State private var confirmingBatchDelete = false

    var body: some View {
        NavigationStack {
            interactiveList
        }
    }

    /// The root list with its INTERACTION layer: drop handling, toolbar and
    /// import entry points. Second slice of the former body chain — the full
    /// chain exceeded the type-checker's complexity budget (CI).
    private var interactiveList: some View {
        presentedList
            .onDrop(of: [UTType.movie],
                    isTargeted: $dropActive,
                    perform: handleDrop)
            .overlay { dropTargetOverlay }
            .navigationTitle("VidCompress")
            .toolbar { importToolbar }
            // Batch actions (selection mode): a bottom bar like native
            // iPadOS list apps — Select all / Save / Delete.
            .toolbar {
                if coordinator.selectionMode {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Select all") { coordinator.selectAllFinished() }
                        Spacer()
                        Button {
                            Task { await coordinator.saveSelectedToPhotos() }
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .disabled(coordinator.selectedIDs.isEmpty)
                        Spacer()
                        Button(role: .destructive) {
                            confirmingBatchDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(coordinator.selectedIDs.isEmpty)
                    }
                }
            }
            // Photos library selection (multi-select → batch)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importFromLibrary(items) }
            }
            // Files app selection (UIDocumentPickerViewController-backed,
            // multi-select → batch)
            .fileImporter(isPresented: $showFiles,
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await importFromFiles(urls) }
                }
            }
    }

    /// Alerts, the setup sheet and the lifecycle tasks. Third slice of the
    /// former body chain.
    private var presentedList: some View {
        queueList
            .alert("Import failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importError ?? "")
            }
            // One-time notice: the system refused background continuation for
            // this install (re-signed bundle IDs are the usual cause). The
            // queue still works — in the foreground only.
            .alert("Background compression unavailable",
                   isPresented: Binding(
                       get: { coordinator.backgroundSubmissionDenied },
                       set: { if !$0 { coordinator.backgroundSubmissionDenied = false } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The system refused background processing for this install — this can happen after the app was re-signed. Compression still works normally; just keep the app open in the foreground until the queue finishes.")
            }
            // Batch save result notice (selection mode).
            .alert("Batch save", isPresented: Binding(
                get: { coordinator.batchNotice != nil },
                set: { if !$0 { coordinator.batchNotice = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(coordinator.batchNotice ?? "")
            }
            // Fat-finger protection for the batch delete.
            .confirmationDialog(
                "Delete \(coordinator.selectedIDs.count) selected items?",
                isPresented: $confirmingBatchDelete,
                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { coordinator.deleteSelected() }
                Button("Keep", role: .cancel) { }
            } message: {
                Text("The selected videos and their history entries will be removed. This cannot be undone.")
            }
            .sheet(isPresented: $showingSetup, onDismiss: {
                setupSheetDismiss()
            }) {
                SetupFlowView(videos: importedVideos,
                              onDone: { showingSetup = false })
                    .presentationDetents([.large])
            }
            .task {
                coordinator.attach(context: modelContext)
                if #available(iOS 26.0, *) {
                    BackgroundCompress.attach(coordinator: coordinator)
                }
                coordinator.loadHistory()
                // Shortcuts handoff: videos added by "Compress video" while
                // the app was away get enqueued now (history first, so the
                // queue spins up against a fully loaded store).
                if #available(iOS 17.0, *) {
                    await VideoInbox.consume(with: coordinator)
                }
            }
            // Shortcuts handoff does not wait for the next launch: a video
            // stashed while the app is merely BACKGROUNDED must be picked up
            // the moment the scene becomes active again (the launch .task
            // above only ever fires once per process).
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, #available(iOS 17.0, *) else { return }
                Task { await VideoInbox.consume(with: coordinator) }
            }
            // Haptic polish, ONE source of truth: the coordinator's ticks
            // fire on terminal transitions regardless of which row a job
            // currently lives in (a finished row MOVES between ForEachs, so
            // per-row feedback was rebuilt around its own event and never
            // fired). Cancellations don't tick — the user did that.
            .sensoryFeedback(.success, trigger: coordinator.completionTick)
            .sensoryFeedback(.error, trigger: coordinator.failureTick)
    }

    /// The scrollable queue/history list — base layer of the former body
    /// chain (content lives in `jobSections` below). Full-width on purpose:
    /// that is the native iPadOS look in fullscreen, and Split View narrow
    /// widths adapt on their own.
    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                jobSections
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: body parts — extracted from `body` so the total expression stays
    // inside the type-checker's complexity budget (CI hit "unable to
    // type-check this expression in reasonable time" once drag & drop landed
    // inline; the same rule the row card already documents).

    @ViewBuilder
    private var jobSections: some View {
        if coordinator.jobs.isEmpty {
            EmptyState(photoItems: $photoItems,
                       onFiles: { showFiles = true })
                .padding(.top, 40)
        }

        // SwiftData fell back to an in-memory store this
        // launch (corrupt document store): the banner explains
        // instead of letting history silently vanish.
        if StorageFallback.inMemoryOnly {
            storageFallbackBanner
        }

        let active = coordinator.jobs.filter {
            [.queued, .analyzing, .compressing, .verifying].contains($0.state)
        }
        let finished = coordinator.jobs.filter {
            [.done, .failed, .cancelled].contains($0.state)
        }

        if !active.isEmpty {
            sectionHeader("In progress", icon: "hourglass", count: active.count)
            ForEach(active) { job in
                JobRowView(job: job)
                    // STABLE identity: ".id(job.id + state)" rebuilt every row on
                    // each state change — the completion haptics never fired
                    // (observer re-created around the event) and any open
                    // dialog/sheet inside a row closed. State is a plain value
                    // read; identity must stay constant per job.
                    .padding(.horizontal)
            }
        }

        if !finished.isEmpty {
            sectionHeader("History", icon: "clock", count: finished.count)
            ForEach(finished) { job in
                JobRowView(job: job)
                    .padding(.horizontal)
            }
        }

        // LIFETIME STATS — the running tally of what the app has
        // actually saved the user, read straight from history.
        LifetimeStatsCard()

        StorageFooter()
            .padding(.top, 6)
    }

    private var importToolbar: some ToolbarContent {
        // Single Group + explicit return: the two-group builder form
        // defeated ToolbarContentBuilder inference (CI type-check error).
        return Group {
            ToolbarItemGroup(placement: .topBarLeading) {
                // SELECTION mode entry (native list-app pattern): batch save
                // and batch delete for finished rows.
                if !coordinator.jobs.isEmpty {
                    Button(coordinator.selectionMode ? "Cancel" : "Select") {
                        if coordinator.selectionMode {
                            coordinator.exitSelectionMode()
                        } else {
                            coordinator.enterSelectionMode()
                        }
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !coordinator.selectionMode {
                    // DIRECT toolbar buttons: a PhotosPicker nested inside a
                    // Menu is unreliable on device (the sheet can be swallowed
                    // by the menu's dismissal). The empty-state pickers — which
                    // work on device — are direct, so the toolbar matches that
                    // proven shape.
                    // preferredItemEncoding: .current — without it the picker
                    // may hand back a TRANSCODED HDR→SDR movie; the engine
                    // must see the original pixels to keep the color tags.
                    PhotosPicker(selection: $photoItems, matching: .videos,
                                 preferredItemEncoding: .current) {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .accessibilityLabel("Import from Photos")

                    Button {
                        showFiles = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel("Import from Files")
                }
            }
        }
    }

    @ViewBuilder
    private var dropTargetOverlay: some View {
        if dropActive {
            RoundedRectangle(cornerRadius: 24)
                .fill(.tint.opacity(0.14))
                .overlay {
                    Label("Drop videos to import", systemImage: "arrow.down.doc")
                        .font(.headline)
                }
                .padding(10)
                .allowsHitTesting(false)
        }
    }

    /// Drop entry point: movies dropped from Files or Photos enter the same
    /// setup flow as picked videos.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !showingSetup, !providers.isEmpty else { return false }
        Task {
            var picked: [PickedVideo] = []
            for provider in providers {
                guard let url = await ImportHelpers.urlFromDrop(provider) else { continue }
                if let copy = await ImportHelpers.copyOffMain(url) {
                    let thumb = await Thumbnails.make(url: copy)
                    picked.append(PickedVideo(url: copy, thumbnail: thumb))
                }
            }
            if picked.isEmpty {
                importError = "The dropped videos could not be imported."
            } else {
                importedVideos = picked
                showingSetup = true
            }
        }
        return true
    }

    private func importFromLibrary(_ items: [PhotosPickerItem]) async {
        var picked: [PickedVideo] = []
        for item in items {
            do {
                let url = try await ImportHelpers.copyFromLibrary(item)
                let thumb = await Thumbnails.make(url: url)
                picked.append(PickedVideo(url: url, thumbnail: thumb))
            } catch {
                // Unreadable/untransferable item — skipped; the
                // batch card shows what made it through.
            }
        }
        photoItems = []
        if picked.isEmpty {
            importError = "The selected videos could not be imported."
        } else {
            importedVideos = picked
            showingSetup = true
        }
    }

    private func importFromFiles(_ urls: [URL]) async {
        var picked: [PickedVideo] = []
        for url in urls {
            // The multi-GB copy runs OFF the main actor —
            // inline on MainActor it froze the UI for the
            // entire copy duration.
            if let copy = await ImportHelpers.copyOffMain(url) {
                let thumb = await Thumbnails.make(url: copy)
                picked.append(PickedVideo(url: copy, thumbnail: thumb))
            }
        }
        if picked.isEmpty {
            importError = "The selected files could not be copied into the app's storage."
        } else {
            importedVideos = picked
            showingSetup = true
        }
    }

    /// The setup sheet closed — Cancel, Compress, or a swipe down. Import
    /// copies that never became a job (cancelled setup, batch videos skipped
    /// after a failed probe) would otherwise leak in Caches/Imports until
    /// the NEXT launch's sweep — multi-GB on large batches. Delete the
    /// leftovers now; enqueued jobs keep their copies (the queue needs them).
    private func setupSheetDismiss() {
        let jobPaths = Set(coordinator.jobs.map {
            $0.sourceURL.standardizedFileURL.path
        })
        let leftovers = importedVideos.map(\.url).filter {
            !jobPaths.contains($0.standardizedFileURL.path)
        }
        JobCoordinator.deleteImportCopies(leftovers)
        importedVideos = []
    }

    private func sectionHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.bold())
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Spacer()
            Text("\(count)")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// One-time banner (stable per-process flag set in App.init): the
    /// SwiftData store failed to open and history runs memory-only.
    private var storageFallbackBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("History may not survive this session — the app couldn't open its database and is running without it. Your videos are not affected.")
                .font(.footnote)
        }
        .padding(12)
        .background(Color(UIColor.systemYellow).opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

// MARK: - Storage footer

/// LIFETIME STATS: "You've saved 12.4 GB". Computed from the persisted
/// history (every done record stores its in/out bytes), so the number is
/// honest — negative deltas (outputs that grew) don't inflate it.
private struct LifetimeStatsCard: View {
    // @Query refreshes itself on every save of the context — the manual
    // NotificationCenter listen was betting on a Core Data name that
    // SwiftData does not re-export, and was never a reliable save-signal.
    @Query(filter: #Predicate<JobRecord> { $0.stateRaw == "done" })
    private var records: [JobRecord]

    private var stats: (videos: Int, saved: Int64) {
        var vids = 0
        var saved: Int64 = 0
        for r in records {
            let delta = r.inBytes - r.outBytes
            if delta > 0 { saved += delta; vids += 1 }
            else if r.outBytes > 0 { vids += 1 }
        }
        return (vids, saved)
    }

    var body: some View {
        Group {
            let s = stats
            if s.videos > 0, s.saved > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill")
                        .font(.callout)
                        .foregroundStyle(Color(UIColor.systemGreen))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You've saved \(ByteCountFormatter.string(fromByteCount: s.saved, countStyle: .file))")
                            .font(.callout.weight(.semibold))
                        Text("Lifetime total across \(s.videos) finished compression\(s.videos == 1 ? "" : "s").")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color(UIColor.systemGreen).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
        }
    }
}

/// Small transparency line: how much storage the app keeps, and the policy.
/// Cleanup itself is automatic (sources deleted after success, orphan sweep
/// at launch) — this just shows the current footprint.
private struct StorageFooter: View {
    @State private var usageText: String?

    var body: some View {
        Group {
            if let usageText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(usageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal)
            }
        }
        .task {
            // Directory sizing is disk I/O — keep it off the main actor.
            let text = await Task.detached { Self.describe() }.value
            usageText = text
        }
    }

    static func describe() -> String? {
        let outputs = dirSize(JobCoordinator.outputsDirectory())
        let imports = dirSize(JobCoordinator.importsDirectory())
        guard outputs + imports > 0 else { return nil }
        let fmt: (Int64) -> String = {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        return "App storage: \(fmt(outputs + imports)) · \(fmt(outputs)) compressed videos kept for sharing — source copies are cleaned up automatically"
    }

    static func dirSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for f in files {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    @Binding var photoItems: [PhotosPickerItem]
    let onFiles: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.badge.ellipsis")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No compressions yet")
                .font(.title3.weight(.semibold))
            Text("Pick one video — or a whole batch — from your library or the Files app to start.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            // Real entry points, not just directions.
            HStack(spacing: 12) {
                // .current encoding: deliver the ORIGINAL pixels — the
                // default may transcode an HDR clip to SDR before the
                // color-safe engine ever sees it.
                PhotosPicker(selection: $photoItems, matching: .videos,
                             preferredItemEncoding: .current) {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: 110)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onFiles) {
                    Label("Files", systemImage: "folder")
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: 110)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            Text("Or drag & drop videos here from Files or Photos while in Split View.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Import helpers

enum ImportHelpers {
    enum ImportError: LocalizedError {
        case notImportable
        var errorDescription: String? {
            "The selected video could not be imported. Try sharing it to the Files app and picking it from there."
        }
    }

    /// PhotosPicker → local copy inside the app's Imports folder. Throws on
    /// total failure so the UI can surface the problem instead of silently
    /// doing nothing.
    static func copyFromLibrary(_ item: PhotosPickerItem) async throws -> URL {
        // Preferred: native URL transferable (iCloud-aware, memory-safe — the
        // system exports the movie to a temp file). Often unavailable for
        // library assets, so failure here just falls through.
        if let url = try? await item.loadTransferable(type: URL.self) {
            // The physical copy runs OFF the main actor — a multi-GB copy
            // inline on MainActor freezes the UI for its whole duration.
            if let copy = await copyOffMain(url) { return copy }
            return url
        }
        // Fallback: FileRepresentation streaming — the system hands us a temp
        // file that we copy to disk. Never holds the whole video in RAM
        // (loading `Data` would OOM-crash on large library files).
        if let video = try? await item.loadTransferable(type: ImportedVideo.self) {
            return video.url
        }
        // The old in-memory `Data` fallback is GONE: a library video that
        // still hit it loaded the WHOLE multi-GB movie into RAM and
        // OOM-crashed the app. An exotic provider that can't hand us a file
        // now gets an honest error alert instead of a crash.
        throw ImportError.notImportable
    }

    /// Security-scoped access + directory transfer, entirely OFF the main
    /// actor: multi-GB copies otherwise stall the UI for their duration.
    static func copyOffMain(_ url: URL) async -> URL? {
        await Task.detached {
            SecurityScoped(url: url).importCopy()
        }.value
    }

    /// Pulls a file URL out of a dropped item provider. Files-app drops hand
    /// over security-scoped URLs; some sources deliver raw Data instead —
    /// written to a temp file first (AVFoundation sniffs the container, the
    /// extension is cosmetic). nil when the provider has nothing usable.
    static func urlFromDrop(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadItem(forTypeIdentifier: UTType.movie.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("drop-\(UUID().uuidString).mov")
                    do {
                        try data.write(to: tmp)
                        cont.resume(returning: tmp)
                    } catch {
                        cont.resume(returning: nil)
                    }
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Coordinated read + copy for files that may be iCloud Drive documents:
    /// a placeholder must be DOWNLOADED before it can be copied, and touching
    /// iCloud documents without an NSFileCoordinator races the sync daemon
    /// (the documented requirement). With .forUploading the coordinator hands
    /// the block a fully materialized file (the same path for plain local
    /// files). Returns false when the copy could not be made.
    static func coordinatedCopy(from url: URL, to dest: URL) -> Bool {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var ok = false
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [.forUploading], error: &coordError) { readURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: dest)
                ok = true
            } catch {
                ok = false
            }
        }
        if let coordError {
            NSLog("VidCompress: coordinated read failed: \(coordError.localizedDescription)")
        }
        return ok
    }
}

/// Memory-safe Transferable for library videos: imports via a file
/// representation instead of an in-memory `Data` blob.
private struct ImportedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url, allowAccessingOriginalFile: true)
        } importing: { received in
            let dir = JobCoordinator.importsDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = received.file.pathExtension
            let ext2 = ext.isEmpty ? "mov" : ext
            let base = "IMG-\(UUID().uuidString)"
            var dest = dir.appendingPathComponent("\(base).\(ext2)")
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(base)-\(n).\(ext2)")
                n += 1
            }
            // FileRepresentation always delivers a real file on disk — copy it
            // directly (NO removeItem first: dest never exists on a fresh
            // import and removing would throw, killing the whole transfer).
            try FileManager.default.copyItem(at: received.file, to: dest)
            return ImportedVideo(url: dest)
        }
    }
}

/// Security-scoped access wrapper for fileImporter (document picker) URLs.
struct SecurityScoped {
    let url: URL
    init(url: URL) { self.url = url }

    func importCopy() -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        // Keep the original filename so history rows and exports are
        // recognizable; add -1, -2, … suffixes on collisions.
        let base = url.deletingPathExtension().lastPathComponent
        let dir = JobCoordinator.importsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        // Coordinated copy: iCloud Drive placeholders get downloaded by the
        // file coordinator first; plain local files copy straight through.
        guard ImportHelpers.coordinatedCopy(from: url, to: dest) else { return nil }
        return dest
    }
}

enum Thumbnails {
    static func make(url: URL, maxDimension: CGFloat = 320, at time: Double? = nil) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 1
        let at = CMTime(seconds: time ?? (dur > 2 ? dur * 0.15 : 0.1), preferredTimescale: 600)
        guard let (img, _) = try? await gen.image(at: at) else { return nil }
        return UIImage(cgImage: img)
    }
}
