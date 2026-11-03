import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

// Root screen: pillar banner + list of compression jobs,
// with the "compressing row" (progress + cancel + error + report).

struct RootView: View {
    @EnvironmentObject private var coordinator: JobCoordinator
    @Environment(\.modelContext) private var modelContext

    @State private var showingSetup = false
    @State private var importedVideos: [PickedVideo] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if coordinator.jobs.isEmpty {
                        EmptyState(photoItems: $photoItems,
                                   onFiles: { showFiles = true })
                            .padding(.top, 40)
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

                    StorageFooter()
                        .padding(.top, 6)
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("VidCompress")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // DIRECT toolbar buttons: a PhotosPicker nested inside a
                    // Menu is unreliable on device (the sheet can be swallowed
                    // by the menu's dismissal). The empty-state pickers — which
                    // work on device — are direct, so the toolbar matches that
                    // proven shape.
                    PhotosPicker(selection: $photoItems, matching: .videos) {
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
            // Photos library selection (multi-select → batch)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
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
            }
            // Files app selection (UIDocumentPickerViewController-backed,
            // multi-select → batch)
            .fileImporter(isPresented: $showFiles,
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task {
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
                }
            }
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
            .sheet(isPresented: $showingSetup) {
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
            }
        }
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
}

// MARK: - Storage footer

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
            usageText = Self.describe()
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
                PhotosPicker(selection: $photoItems, matching: .videos) {
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
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return nil }
        return dest
    }
}

enum Thumbnails {
    static func make(url: URL, maxDimension: CGFloat = 320) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 1
        let at = CMTime(seconds: dur > 2 ? dur * 0.15 : 0.1, preferredTimescale: 600)
        guard let (img, _) = try? await gen.image(at: at) else { return nil }
        return UIImage(cgImage: img)
    }
}
