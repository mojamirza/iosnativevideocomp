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
    @State private var importedURL: URL?
    @State private var importedThumb: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showFiles = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if coordinator.jobs.isEmpty {
                        EmptyState()
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
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("VidCompress")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PhotosPicker(selection: $photoItem, matching: .videos) {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    Button {
                        showFiles = true
                    } label: {
                        Image(systemName: "folder")
                    }
                }
            }
            // Photos library selection
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let url = await ImportHelpers.copyFromLibrary(item) {
                        let thumb = await Thumbnails.make(url: url)
                        importedURL = url
                        importedThumb = thumb
                        showingSetup = true
                    }
                    photoItem = nil
                }
            }
            // Files app selection (UIDocumentPickerViewController-backed)
            .fileImporter(isPresented: $showFiles,
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task {
                        if let copy = SecurityScoped(url: url).importCopy() {
                            let thumb = await Thumbnails.make(url: copy)
                            importedURL = copy
                            importedThumb = thumb
                            showingSetup = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSetup) {
                if let url = importedURL {
                    SetupFlowView(sourceURL: url,
                                  thumbnail: importedThumb,
                                  onDone: { showingSetup = false })
                        .presentationDetents([.large])
                }
            }
            .task {
                coordinator.attach(context: modelContext)
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

// MARK: - Empty state

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.badge.ellipsis")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No compressions yet")
                .font(.title3.weight(.semibold))
            Text("Use the photo or folder buttons in the top corner to pick a video from your Photos library or the Files app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Import helpers

enum ImportHelpers {
    /// PhotosPicker → local copy inside the app's Imports folder.
    static func copyFromLibrary(_ item: PhotosPickerItem) async -> URL? {
        // Preferred: native URL transferable (iCloud-aware).
        if let url = try? await item.loadTransferable(type: URL.self) {
            return SecurityScoped(url: url).importCopy() ?? url
        }
        // Fallback: stream the file representation to disk. Loading the item
        // as `Data` would hold the ENTIRE video in RAM and OOM-crash on large
        // library files — loadFileRepresentation hands us a temp file instead.
        let dir = JobCoordinator.importsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mov"
        let suggested = item.itemIdentifier.map { "IMG-\($0.uuidString).\(ext)" }
            ?? "IMG-\(UUID().uuidString.prefix(8)).\(ext)"
        let dest = dir.appendingPathComponent(suggested)
        if await copyViaItemProvider(item, to: dest) {
            return dest
        }
        return nil
    }

    /// Streams a PhotosPickerItem to a destination file using the provider's
    /// file representation (never holds the whole video in memory).
    private static func copyViaItemProvider(_ item: PhotosPickerItem,
                                            to dest: URL) async -> Bool {
        guard let provider = item.itemProvider else { return false }
        // Type identifiers that actually hold video data, most preferred first.
        let candidates = ["com.apple.quicktime-movie", AVFileType.mov.rawValue,
                          AVFileType.mp4.rawValue, "public.movie"]
        let typeID = candidates.first { provider.hasItemConformingToTypeIdentifier($0) }
            ?? "public.movie"
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { tempURL, err in
                guard let tempURL, err == nil else {
                    cont.resume(returning: false)
                    return
                }
                // The temp URL is only valid inside this handler — copy it NOW.
                try? FileManager.default.removeItem(at: dest)
                let ok = (try? FileManager.default.copyItem(at: tempURL, to: dest)) != nil
                cont.resume(returning: ok)
            }
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
