import AppIntents
import UniformTypeIdentifiers
import SwiftUI
import UIKit

/// Shortcuts action: "Compress video". The intent hands the video to the
/// app via a persisted INBOX (Application Support, outside the Files-visible
/// folder); the app enqueues it on launch with the preset last used in the
/// setup flow — the same flow a normal import takes, minus the setup screen.
///
/// (A Share extension was considered for the same job: it needs an App Group
/// entitlement to move a video across the extension↔app sandbox, which free
/// personal re-signing cannot grant — the action would silently fail on the
/// sideloaded device. The Shortcuts route ships instead; zero entitlements.)
@available(iOS 17.0, *)
struct CompressVideoIntent: AppIntent {

    static let title: LocalizedStringResource = "Compress video"
    static var description: IntentDescription {
        // Matches consume(): the preset is the one last run from setup,
        // not a fixed built-in.
        "Add a video to the VidCompress queue using your last-used preset."
    }
    // Launches the app so the queue worker owns the encode (as always).
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Video")
    var video: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        try await VideoInbox.stash(file: video)
        // The app may already be active (openAppWhenRun): consume NOW, not
        // at the next activation — the marker exists at this point.
        await VideoInbox.consumeFromHost()
        return .result()
    }
}

@available(iOS 17.0, *)
struct CompressVideoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CompressVideoIntent(),
            phrases: [
                "Compress video in \(.applicationName)",
                "Compress with \(.applicationName)",
            ],
            shortTitle: "Compress video",
            systemImageName: "arrow.down.forward.circle.fill")
    }
}

/// The handoff mailbox between Shortcuts and the app's job queue:
/// the intent copies the video to Imports (same lifecycle as every other
/// import — cleaned up after success) and drops a marker file; the app
/// consumes markers on launch and enqueues the videos.
enum VideoInbox {

    /// Re-entrancy guard for consume(with:) — see its doc comment.
    @MainActor private static var consumeInFlight = false

    /// NOT the Files-visible Documents tree: only the marker JSONs live here.
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? JobCoordinator.outputsDirectory()
        return support.appendingPathComponent("Inbox", isDirectory: true)
    }

    struct Marker: Codable {
        var urls: [String]
    }

    /// Copies the Shortcut's file into the app's Imports folder — ideally
    /// without ever materialising a multi-GB video in RAM — and records a
    /// marker the app consumes on launch.
    @available(iOS 17.0, *)
    static func stash(file: IntentFile) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let src = file.fileURL
        let extRaw = file.type?.preferredFilenameExtension ?? src?.pathExtension ?? "mov"
        let ext = extRaw.isEmpty ? "mov" : extRaw
        let base = ((src?.lastPathComponent as NSString?)?.deletingPathExtension ?? "")
            .replacingOccurrences(of: "/", with: "-")
        var stem = String(base.prefix(60))
        if stem.isEmpty { stem = "Shortcut video" }
        let importDir = JobCoordinator.importsDirectory()
        try fm.createDirectory(at: importDir, withIntermediateDirectories: true)
        var dest = importDir.appendingPathComponent("\(stem).\(ext)")
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = importDir.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }

        // IMMUTABLE copies only: `dest` keeps mutating in the dedup loop
        // above, and a concurrently-executing (@Sendable) closure may not
        // capture mutable state — pin the final path down before detaching.
        let target = dest
        let copied: Bool = await Task.detached {
            guard let src else { return false }
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            // Coordinated copy: iCloud Drive placeholders are downloaded by
            // the file coordinator before the copy (plain files pass through).
            return ImportHelpers.coordinatedCopy(from: src, to: target)
        }.value
        if !copied && !fm.fileExists(atPath: target.path) {
            // Rare provider without a file URL: honest small-file fallback.
            let data = try file.data
            try data.write(to: target)
        }

        let marker = directory.appendingPathComponent("\(UUID().uuidString).json")
        let payload = try JSONEncoder().encode(Marker(urls: [target.standardizedFileURL.path]))
        // ATOMIC: consume() scans for *.json — a plain write can expose a
        // half-written marker, which consume() treats as corrupt and deletes
        // (video never enqueued, no feedback). The atomic temp+rename makes
        // a marker visible only once it is complete.
        try payload.write(to: marker, options: .atomic)
    }

    /// Paths of videos currently marked in the inbox. The launch/orphan
    /// sweep unites these into its keep set: a stashed import copy can sit
    /// here waiting for the app to become active — the sweep would
    /// otherwise delete it as an orphan after the 1-hour freshness window
    /// even though the marker (the intent to compress it) still exists.
    /// CLAIMED (`.processing`) markers count too — they record the same
    /// intent, just mid-handoff (a kill between claim and commit must not
    /// turn their copies into swept orphans).
    static func pendingPaths() -> Set<String> {
        let fm = FileManager.default
        guard let markers = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var paths = Set<String>()
        for marker in markers
        where ["json", "processing"].contains(marker.pathExtension) {
            guard let payload = try? Data(contentsOf: marker),
                  let decoded = try? JSONDecoder().decode(Marker.self, from: payload)
            else { continue }
            paths.formUnion(decoded.urls)
        }
        return paths
    }

    @MainActor
    static func consume(with coordinator: JobCoordinator) async {
        guard !consumeInFlight else { return }
        consumeInFlight = true
        defer { consumeInFlight = false }
        let fm = FileManager.default
        var pass = 0
        while pass < 3 {
            pass += 1
            guard let listing = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return }
            // RECOVERY of a KILLED run: a marker claimed for processing but
            // never committed stays as `.processing` forever — renew it to
            // the ordinary pending set so this run processes it. The old
            // delete-then-work order made any kill in the multi-second
            // probe/plan/thumbnail window destroy the ONLY record of the
            // handoff (copies were swept later; the Shortcut silently did
            // nothing). One already-enqueued video can re-enqueue as a
            // duplicate row after the recovery — but the dedup guard below
            // skips active jobs, so the real-world cost is nothing next
            // to the pre-fix total loss.
            for stale in listing where stale.pathExtension == "processing" {
                try? fm.moveItem(at: stale, to: stale
                    .deletingPathExtension().appendingPathExtension("json"))
            }
            // FRESH scan AFTER recovery: renewed markers are ordinary json
            // markers in THIS pass.
            guard let markers = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return }
            let jsons = markers.filter { $0.pathExtension == "json" }
            guard !jsons.isEmpty else { return }
            for marker in jsons {
                guard let payload = try? Data(contentsOf: marker),
                      let decoded = try? JSONDecoder().decode(Marker.self, from: payload)
                else {
                    try? fm.removeItem(at: marker)
                    continue
                }
                // CLAIM: rename to `.processing` FIRST, commit (delete) only
                // after EVERY URL is enqueued. A kill any time in between
                // leaves the claim behind → the recovery pass above (and the
                // sweep's keep set) still represents the handoff.
                let claimed = marker
                    .deletingPathExtension().appendingPathExtension("processing")
                try? fm.moveItem(at: marker, to: claimed)
                let work = fm.fileExists(atPath: claimed.path) ? claimed : marker
                for rawPath in decoded.urls {
                    let url = URL(fileURLWithPath: rawPath)
                    guard fm.fileExists(atPath: url.path) else {
                        // Missing copy: SAY so — the probe-failure branch
                        // already surfaces a notice; the old silent
                        // continue read as "the action did nothing".
                        coordinator.importNotice = "“\(url.lastPathComponent)” shared from Shortcuts is no longer in the inbox (its copy was removed)."
                        continue
                    }
                    // DEDUP against the recovery path: if the previous run
                    // enqueued this very copy before being killed, an active
                    // job (queued/resumed) already owns it — re-enqueueing
                    // would compress the same video twice.
                    let path = url.standardizedFileURL.path
                    if coordinator.jobs.contains(where: {
                        $0.sourceURL.standardizedFileURL.path == path &&
                        [.queued, .analyzing, .compressing, .verifying].contains($0.state)
                    }) {
                        continue
                    }
                    guard let probe = try? await ProbeResult.probe(url: url) else {
                        // Undecodable handoff: delete the copy — but SAY so.
                        // The old silent delete meant “I ran the action and
                        // nothing happened.” The notice surfaces as a
                        // RootView alert.
                        try? fm.removeItem(at: url)
                        coordinator.importNotice = "“\(url.lastPathComponent)” shared from Shortcuts couldn't be read as a video and was removed."
                        continue
                    }
                    // Respect the user's habitual choice: the last preset
                    // actually run from setup (SetupFlow persists it on every
                    // commit), falling back to the first built-in when the
                    // stored id no longer resolves (deleted custom).
                    let lastID = PresetStore.lastUsedPresetID()
                    let preset = Preset.builtIn.first { $0.id == lastID }
                        ?? PresetStore.loadCustom().first { $0.id == lastID }
                        ?? Preset.builtIn[0]
                    let plan = QualitySizeOptimizer.plan(preset: preset, probe: probe)
                    let thumb = await Thumbnails.make(url: url)
                    coordinator.enqueue(source: url, probe: probe, plan: plan,
                                        preset: preset, thumbnail: thumb)
                }
                // COMMIT — only now does the handoff record go away.
                try? fm.removeItem(at: work)
            }
        }
    }

    /// The Shortcuts intent calls this at the END of perform(): the app can
    /// already be active by the time the multi-GB copy finishes, and without
    /// this the marker would sit until the next activation. No-op when the
    /// host coordinator isn't around yet.
    @MainActor
    static func consumeFromHost() async {
        guard let coordinator = hostCoordinator else { return }
        await consume(with: coordinator)
    }

    /// Set by RootView at launch (like BackgroundCompress.attach).
    @MainActor
    static weak var hostCoordinator: JobCoordinator?
}
