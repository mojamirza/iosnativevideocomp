import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

// Root screen: pillar banner + list of compression jobs,
// with the "compressing row" (progress + cancel + error + report).

struct RootView: View {
    @EnvironmentObject private var coordinator: JobCoordinator

    @State private var showingSetup = false
    @State private var importedURL: URL?
    @State private var importedThumb: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showFiles = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    HeaderCard()
                        .padding(.horizontal)

                    if coordinator.jobs.isEmpty {
                        EmptyState()
                            .padding(.top, 40)
                    }

                    let active = coordinator.jobs.filter {
                        [.queued, .analyzing, .compressing].contains($0.state)
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

// MARK: - Header / pillar card

private struct HeaderCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(LinearGradient(colors: [.blue, .teal],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("Native iPad compression")
                    .font(.headline)
                Label("Color-safe engine", systemImage: "paintpalette.fill")
                Label("Quality–size optimizer", systemImage: "scalemass")
                Label("Output integrity report", systemImage: "checkmark.seal.fill")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
    }
}

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
        // Fallback: raw bytes.
        if let data = try? await item.loadTransferable(type: Data.self) {
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mov"
            let dir = JobCoordinator.importsDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("IMG-\(UUID().uuidString.prefix(8)).\(ext)")
            try? data.write(to: dest)
            return dest
        }
        return nil
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
        let dir = JobCoordinator.importsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
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
        let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 1
        let at = CMTime(seconds: dur > 2 ? dur * 0.15 : 0.1, preferredTimescale: 600)
        guard let (img, _) = try? await gen.image(at: at) else { return nil }
        return UIImage(cgImage: img)
    }
}
