import Foundation
import SwiftUI
import SwiftData
import AVFoundation

/// Raised BEFORE any bytes are written when the output volume can't hold the
/// planned result (with a working margin) — a multi-GB encode onto a nearly
/// full disk otherwise dies mid-write with a confusing encoder error (or
/// fills the disk for every other app on the device).
struct InsufficientSpaceError: LocalizedError {
    let neededBytes: Int64
    let freeBytes: Int64

    var errorDescription: String? {
        let need = ByteCountFormatter.string(fromByteCount: neededBytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "Not enough free space — this compression needs about \(need) free, but only \(free) is available. Free up storage and tap Retry."
    }
}

@MainActor
final class JobCoordinator: ObservableObject {

    enum JobState: String, Codable {
        case queued, analyzing, compressing, verifying, done, failed, cancelled
    }

    struct Job: Identifiable {
        let id: UUID
        var sourceURL: URL
        var sourceName: String
        var preset: Preset
        var state: JobState
        var progress: Double = 0
        var plan: OptimizerPlan?
        var report: IntegrityReport?
        var errorMessage: String?
        var outputURL: URL?
        var thumbnail: UIImage?
        var createdAt = Date()
        /// When the encode actually started (nil until .compressing) — the
        /// row derives encode speed and ETA from this, proving the job is
        /// alive without inventing fake progress.
        var startedAt: Date?
    }

    @Published var jobs: [Job] = []

    private var workerTask: Task<Void, Never>?
    /// Bumped every time a worker is spawned or retired, so a late-waking old
    /// worker's `defer` can't nil out a NEW worker's task reference.
    private var workerGeneration = 0
    private var cancelFlags: [UUID: EngineFlags] = [:]
    /// Jobs whose thumbnail was already (re)generated this process — history
    /// rows are rebuilt thumbnail-less at relaunch and must not re-decode a
    /// frame on every lazy row appearance.
    private var thumbnailAttempts = Set<UUID>()
    /// Jobs whose engine was stopped because iOS revoked the background task.
    /// They become FAILED rows (source kept, Retry available) instead of
    /// silently vanishing.
    private var systemInterrupted = Set<UUID>()
    /// One-shot UI flag: the system REFUSED the BG continued-processing
    /// submission — after a Sideloadly re-sign the bundle ID may no longer
    /// match the task identifier, and submission then fails silently.
    /// Foreground compression is unaffected.
    @Published var backgroundSubmissionDenied = false
    private var submitDenialNoticed = false
    private var modelContext: ModelContext?

    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    /// Attach the SwiftData context from the SwiftUI environment (attached from RootView).
    func attach(context: ModelContext?) {
        self.modelContext = context
    }

    // MARK: Import / enqueue

    func enqueue(source url: URL, probe: ProbeResult, plan: OptimizerPlan, preset: Preset, thumbnail: UIImage?) {
        let job = Job(id: UUID(),
                      sourceURL: url,
                      sourceName: url.lastPathComponent,
                      preset: preset,
                      state: .queued,
                      plan: plan,
                      thumbnail: thumbnail,
                      createdAt: Date())
        jobs.insert(job, at: 0)
        runQueueIfNeeded()
    }

    // MARK: Queue processing (one job at a time for a stable iPad experience)

    /// True while the in-app (foreground) worker owns the queue — the BG
    /// driver defers to it to avoid double processing.
    var foregroundWorkerActive: Bool { workerTask != nil }

    /// Starts driving the queue. The in-app worker starts INSTANTLY (no wait
    /// for the system), and on iOS 26+ a BGContinuedProcessingTask is
    /// submitted alongside as a background lifeline: its handler waits for
    /// the in-app worker, sweeps the rest of the queue, and keeps the app
    /// unsuspended mid-encode. If the submission is refused, everything
    /// still works in the foreground exactly like before.
    private func runQueueIfNeeded() {
        startForegroundWorker()
        if #available(iOS 26.0, *) {
            if BackgroundCompress.isRegistered, !BackgroundCompress.isRunning {
                let hasWork = jobs.contains {
                    [.queued, .analyzing, .compressing, .verifying].contains($0.state)
                }
                guard hasWork else { return }
                let current = jobs.first {
                    [.compressing, .analyzing, .verifying].contains($0.state)
                }
                let subtitle = current?.sourceName
                    // Name the job that will encode NEXT (the oldest queued
                    // pick — same rule as the workers), not the newest row.
                    ?? jobs.last(where: { $0.state == .queued })?.sourceName
                    ?? "videos"
                if !BackgroundCompress.submit(subtitle: subtitle), !submitDenialNoticed {
                    // The refusal previously vanished: background
                    // continuation silently lost for the whole session
                    // (bundle-ID/task-identifier mismatch after a re-sign
                    // is a classic cause). One-time notice instead.
                    submitDenialNoticed = true
                    backgroundSubmissionDenied = true
                }
            }
        }
    }

    /// The in-app worker — always the foreground executor (instant start).
    private func startForegroundWorker() {
        if #available(iOS 26.0, *) {
            // The BG driver owns the queue while its task is running — it
            // picks up new jobs itself. (Prevents two concurrent encodes.)
            if BackgroundCompress.isRunning { return }
        }
        guard workerTask == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        workerTask = Task { [weak self] in
            defer {
                if let self, self.workerGeneration == generation {
                    self.workerTask = nil
                }
            }
            while !Task.isCancelled {
                guard let self,
                      // PICK ORDER: the array is newest-first (enqueue inserts
                      // at 0 for the history display), so the LAST queued
                      // entry is the OLDEST pick — batch jobs encode in the
                      // order the user selected instead of reversed.
                      let idx = self.jobs.lastIndex(where: { $0.state == .queued }) else { break }
                // Claim the job atomically (MainActor) BEFORE running it, so a
                // revived second worker can never double-process the same job.
                self.jobs[idx].state = .analyzing
                let id = self.jobs[idx].id
                await self.run(jobID: id)
            }
        }
    }

    func run(jobID: UUID) async {
        // Fresh run: any earlier system-interruption mark is stale.
        systemInterrupted.remove(jobID)
        // The queue claim already moved this job out of .queued; if a watchdog
        // force-finished it in the meantime, do nothing (never re-run a job
        // that reached a terminal state).
        guard let job = jobs.first(where: { $0.id == jobID }),
              ![JobState.done, .failed, .cancelled].contains(job.state) else { return }
        let flags = EngineFlags()
        cancelFlags[jobID] = flags

        let fm = FileManager.default
        // Working scratch (app-owned, invisible in Files): the encode AND the
        // verification run HERE; the file is promoted to Documents only after
        // a passing verdict. A crash/kill mid-write therefore leaves its
        // partial file where the user cannot see it, and the sweep erases it
        // on the next launch.
        let workDir = Self.workingDirectory()
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let workURL = workDir.appendingPathComponent("\(jobID.uuidString).mp4")
        // A retry (or an earlier interrupted attempt) reuses the jobID — a
        // stale scratch file must not survive into this run.
        try? fm.removeItem(at: workURL)
        // The public name — and its forced .mp4 extension (the muxed
        // container is MP4 regardless of the source) — is chosen by promote()
        // at SUCCESS time only, collision-proof on disk: a queued twin job
        // can never be overwritten.
        let output = workURL

        // analyzing
        setJob(jobID) { $0.state = .analyzing }
        bgSubtitle("Analyzing \(job.sourceName)…")
        let encodeStart = Date()

        do {
            var plan: OptimizerPlan
            if let p = job.plan {
                plan = p
            } else {
                let probe = try await ProbeResult.probe(url: job.sourceURL)
                plan = QualitySizeOptimizer.plan(preset: job.preset, probe: probe)
                setJob(jobID) { $0.plan = plan }
            }

            // FREE-SPACE PREFLIGHT: the planned output (with a working
            // margin) must fit in the volume's free space BEFORE any bytes
            // are written — a multi-GB encode onto a nearly-full disk
            // otherwise dies mid-write with a confusing encoder error (or
            // fills the disk for every other app). Target-size jobs budget
            // TWO outputs: the measured correction pass writes a second
            // scratch file while the first pass's file still exists.
            if let free = Self.volumeFreeBytes(at: workDir) {
                let base = plan.targetBytes ?? plan.estimatedBytes
                let factor: Double = plan.targetBytes != nil ? 2.0 : 1.2
                let needed = Int64((Double(base) * factor).rounded()) + 64_000_000
                if free < needed {
                    throw InsufficientSpaceError(neededBytes: needed, freeBytes: free)
                }
            }

            setJob(jobID) {
                $0.state = .compressing
                $0.progress = 0
                $0.startedAt = Date()
            }
            bgSubtitle("Encoding \(job.sourceName)…")

            // NOTE: there is deliberately NO coordinator-side encode watchdog.
            // The earlier 20 s progress-stall backstop failed slow or
            // app-suspended jobs WITHOUT stopping the engine, dropped the
            // cancel flags, and revived a second worker — two encodes could
            // then run at once and the abandoned one overwrote the failed
            // state when it later finished. The engine owns stall/cancel
            // detection (120 s heartbeat watchdog); a system revocation is
            // handled by cancelActiveForBackgroundExpiry(), which DOES stop
            // the engine before marking the row.

            // The engine RETURNS the audio rate it actually applied (its
            // canApply ladder may step down from the plan's request) — the
            // plan carries the truly-encoded number into the verifier, so
            // the report's bitrate math and the file agree.
            let audioApplied = try await CompressionEngine.compress(
                source: job.sourceURL,
                output: output,
                preset: job.preset,
                plan: plan,
                flags: flags
            ) { [weak self] progress in
                Task { @MainActor in
                    // Monotonic: a stale engine emission (an earlier
                    // attempt, a re-anchored VFR source) must never drag
                    // the row backward mid-encode.
                    self?.setJob(jobID) { $0.progress = max($0.progress, progress) }
                    self?.bgProgress(name: job.sourceName, fraction: progress)
                }
            }
            plan.audioBitrate = audioApplied

            // ----------------------------------------------------------------
            // GUARANTEED TARGET SIZE — the hard promise. The plan already
            // solved its bitrate against the budget (SizeMath, 95 % fill);
            // now MEASURE the real bytes and, on an overshoot, re-encode
            // with a corrected rate — up to TWO passes, both solved from
            // measurements (never guesses), each aimed at the slightly
            // lower correction fill (0.92) for extra closure slack.
            // ----------------------------------------------------------------
            if let target = plan.targetBytes, target > 0 {
                var pass = 0
                while pass < 2 {
                    let bytes = (try? fm.attributesOfItem(atPath: output.path))?[.size]
                        as? Int64 ?? 0
                    if bytes <= target { break }
                    pass += 1
                    let audioBytes = Double(plan.audioBitrate) / 8.0 * max(0.1, plan.duration)
                    let overhead = SizeMath.containerOverhead(forBytes: Double(target))
                    let videoActual = max(1.0, Double(bytes) - audioBytes - overhead)
                    let videoBudget = max(1.0, (Double(target) - overhead)
                        * SizeMath.correctionFill - audioBytes)
                    let corrected = min(SizeMath.maxVideoBitrate, max(SizeMath.minVideoBitrate,
                        Int(Double(plan.videoBitrate) * videoBudget / videoActual)))
                    // The measured rate is ALREADY at/below what the encoder
                    // managed to undershoot to — a "correction" upward would
                    // encode BIGGER; stop instead (the verifier decides).
                    if corrected >= plan.videoBitrate { break }
                    var next = plan
                    next.videoBitrate = corrected

                    // Deliberate progress reset: the measured correction
                    // pass restarts the bar (the monotonic guard in the
                    // callback resumes from 0 cleanly after this).
                    setJob(jobID) {
                        $0.state = .compressing
                        $0.progress = 0
                    }
                    bgSubtitle("Re-encoding \(job.sourceName) to fit…")

                    // Each corrected pass encodes to a SEPARATE scratch;
                    // only on full success does it replace the primary path,
                    // so a mid-re-encode cancel/kill still presents a
                    // consistent state to the sweep and the verifier below.
                    let extra = workDir.appendingPathComponent("\(jobID.uuidString).r\(pass + 1).mp4")
                    try? fm.removeItem(at: extra)
                    let audioApplied = try await CompressionEngine.compress(
                        source: job.sourceURL,
                        output: extra,
                        preset: job.preset,
                        plan: next,
                        flags: flags
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.setJob(jobID) { $0.progress = max($0.progress, progress) }
                            self?.bgProgress(name: job.sourceName, fraction: progress)
                        }
                    }
                    next.audioBitrate = audioApplied
                    // Swap the scratch files; downstream (verify/promote)
                    // keeps using the ONE primary path.
                    try? fm.removeItem(at: output)
                    try fm.moveItem(at: extra, to: output)
                    plan = next
                }
            }

            setJob(jobID) {
                $0.state = .verifying
                $0.progress = 1.0
            }
            bgSubtitle("Verifying \(job.sourceName)…")

            // HARD GUARANTEE: verification is internally capped at 60 s, but
            // if anything wedges beyond that (worker task never resuming,
            // SwiftData stall, …), this independent watchdog forces the row
            // terminal. The job list can never show "Verifying…" forever.
            // MONOTONIC deadline (systemUptime, not Date()): wall-clock
            // jumps (NTP sync, timezone) could fire the backstop early or
            // late. systemUptime is monotonic.
            let verifyDeadline = ProcessInfo.processInfo.systemUptime
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                self?.forceVerifyTerminal(jobID: jobID, output: output,
                                          encodeSeconds: Date().timeIntervalSince(encodeStart),
                                          startedAt: verifyDeadline)
            }

            // Integrity verification (third pillar).
            let report = await IntegrityVerifier.verify(
                source: job.sourceURL,
                output: output,
                probe: plan.source,
                plan: plan,
                encodeSeconds: Date().timeIntervalSince(encodeStart)
            )
            // Late wake-up guard: if forceVerifyTerminal fired while run()
            // was wedged (the very case that function exists for), the row
            // was already finalised AND the file promoted out of scratch.
            // Continuing here would either fail to move a no-longer-existing
            // file or overwrite the good row with a stale result — simply
            // discard the scratch and yield.
            guard jobs.first(where: { $0.id == jobID })?.state == .verifying else {
                try? fm.removeItem(at: output)
                return
            }

            let reportData = try? JSONEncoder().encode(report)
            // Three-state verdict: a FAILED report fails the job; a WARN-only
            // report (timed-out verification, inconclusive decode) still
            // completes the job as done — the row just shows "not fully
            // verified" instead of a green seal.
            let encodeOK = report.status != .failed

            // SUCCESS-ONLY promotion (shared helper): rename the verified
            // file into Documents under its collision-proof public name.
            // A failing move is a REAL failure — a "done" row whose file
            // stayed in scratch would be erased by the next sweep while the
            // record keeps showing outputFileName — so it marks the row
            // failed instead.
            if encodeOK {
                guard let promoted = promote(output,
                                             sourceName: job.sourceName,
                                             preset: job.preset) else {
                    let msg = "Couldn't save the file to Files — free up storage and tap Retry."
                    setJob(jobID) {
                        $0.state = .failed
                        $0.errorMessage = msg
                    }
                    saveRecord(jobID: jobID, outputName: nil, report: nil,
                               state: "failed", errorText: msg)
                    cancelFlags.removeValue(forKey: jobID)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    return
                }
                setJob(jobID) {
                    $0.state = .done
                    $0.report = report
                    $0.outputURL = promoted
                }
                // A cancel that landed during verification: honour it — remove
                // the row entirely, unless iOS interrupted us (then keep a
                // retryable failed row).
                if flags.cancelled {
                    if systemInterrupted.contains(jobID) {
                        markInterrupted(jobID: jobID, output: promoted)
                    } else {
                        removeRow(jobID: jobID)
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    return
                }
                saveRecord(jobID: jobID, outputName: promoted.lastPathComponent,
                           report: reportData, state: "done")
                // Storage management: a finished job doesn't need our copy of
                // the source anymore — the original still lives in Photos/Files.
                deleteSourceImport(job)
            } else {
                // HARD integrity failure: the row keeps its scratch file for
                // INSPECTION (the report is attached; "Keep anyway" promotes
                // it to Documents as a manual verdict override), but no
                // record outputName — the next launch's sweep legitimately
                // erases scratch, and no record may point there.
                setJob(jobID) {
                    $0.state = .failed
                    $0.report = report
                    $0.outputURL = output
                    $0.errorMessage = "Output integrity report failed — see details. Keep the file anyway from the ⋯ menu if it plays fine."
                }
                if flags.cancelled {
                    if systemInterrupted.contains(jobID) {
                        markInterrupted(jobID: jobID, output: output)
                    } else {
                        removeRow(jobID: jobID)
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    return
                }
                saveRecord(jobID: jobID, outputName: nil,
                           report: reportData, state: "failed")
            }

        } catch is CancellationError {
            handleCancelled(jobID: jobID, output: output)
        } catch CompressionError.cancelled {
            handleCancelled(jobID: jobID, output: output)
        } catch {
            setJob(jobID) {
                $0.state = .failed
                $0.errorMessage = error.localizedDescription
            }
            saveRecord(jobID: jobID, outputName: nil, report: nil, state: "failed",
                       errorText: error.localizedDescription)
        }

        cancelFlags.removeValue(forKey: jobID)
        // Give the UI a frame to settle before the next job starts.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// A user cancel removes everything; a system interruption (background
    /// task revoked) keeps a retryable failed row instead.
    private func handleCancelled(jobID: UUID, output: URL) {
        if systemInterrupted.contains(jobID) {
            markInterrupted(jobID: jobID, output: output)
        } else {
            // Cancelled jobs leave no trace: no row, no record, no partial file.
            removeRow(jobID: jobID)
        }
    }

    /// The system revoked the background task mid-job: keep the row as FAILED
    /// (source kept, Retry available) and drop the partial output.
    private func markInterrupted(jobID: UUID, output: URL) {
        systemInterrupted.remove(jobID)
        cancelFlags.removeValue(forKey: jobID)
        setJob(jobID) {
            $0.state = .failed
            $0.progress = 0
            $0.errorMessage = "Interrupted by iOS in the background — tap Retry."
        }
        try? FileManager.default.removeItem(at: output)
        saveRecord(jobID: jobID, outputName: nil, report: nil, state: "failed",
                   errorText: "Interrupted by iOS in the background.")
    }

    /// Watchdog backstop for the VERIFY phase: only acts if the job is STILL
    /// in .verifying (the normal path finishes in ≤60 s and has already moved
    /// the row on). Unlike the deleted compress watchdog, verification is
    /// read-only (no live engine running), so forcing the row terminal here
    /// cannot leave a second encode running.
    private func forceVerifyTerminal(jobID: UUID, output: URL, encodeSeconds: Double, startedAt: TimeInterval) {
        guard ProcessInfo.processInfo.systemUptime - startedAt >= 74 else { return }
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[idx].state == .verifying else { return }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int64) ?? 0
        let report = IntegrityReport(
            items: [ReportItem("verify", "Verification timed out",
                "The integrity checks took too long and were stopped. The output file was finalized by the encoder — if it plays in Files, it is good.", .warn)],
            inBytes: jobs[idx].plan?.source.fileSize ?? 0,
            outBytes: fileSize,
            outputBitrateMbps: nil,
            encodeSeconds: encodeSeconds,
            outputDuration: nil)
        // Promote exactly like a normal success: without this the verified
        // file is STRANDED in scratch — the record would carry the scratch
        // name ("<jobID>.mp4"), loadHistory would find no such file in
        // Documents ("File removed"), and the sweep would erase it.
        if let final = promote(output, sourceName: jobs[idx].sourceName,
                               preset: jobs[idx].preset) {
            jobs[idx].state = .done
            jobs[idx].report = report
            jobs[idx].outputURL = final
            noteTerminalTick(.done)
            saveRecord(jobID: jobID, outputName: final.lastPathComponent,
                       report: try? JSONEncoder().encode(report), state: "done")
        } else {
            // Same rule as run(): a promotion failure must NOT fall back to
            // rescuing a scratch path — the record would point at a file the
            // next sweep erases. Fail the job with Retry (the source import
            // survived: only verification wedged).
            let msg = "Couldn't save the file to Files — free up storage and tap Retry."
            jobs[idx].state = .failed
            jobs[idx].errorMessage = msg
            noteTerminalTick(.failed)
            try? FileManager.default.removeItem(at: output)
            saveRecord(jobID: jobID, outputName: nil, report: nil, state: "failed",
                       errorText: msg)
        }
        cancelFlags.removeValue(forKey: jobID)
        // The worker task is wedged (that's why we're here) — retire it and
        // start a fresh one so the queue keeps working. A late-waking old
        // worker can't double-process: jobs are claimed out of .queued and
        // run() refuses already-terminal jobs.
        reviveWorker()
    }

    // MARK: Actions

    func cancel(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[idx].state == .queued {
            // Never started — just drop it. The source import copy leaves
            // TOO: removing only the row leaked the multi-GB copy in
            // Caches/Imports until the next sweep.
            deleteSourceImport(jobs[idx])
            withAnimation { jobs.remove(at: idx) }
        } else if let flags = cancelFlags[jobID] {
            // Active job: the engine's cancel hooks abort the encode at once;
            // run() then removes the row entirely (cancelled jobs leave no
            // record and no list entry).
            flags.cancel()
        }
    }

    func retry(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              [JobState.failed, .cancelled].contains(jobs[idx].state),
              FileManager.default.fileExists(atPath: jobs[idx].sourceURL.path) else { return }
        // A failed run keeps its output (report rows can inspect it). This
        // fresh attempt REPLACES it: remove the old file up front so Retry
        // can't stack "name (2)" files beside a file the user already
        // rejected — and can't ever resurrect a bad verdict's artifact.
        if let url = jobs[idx].outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        jobs[idx].outputURL = nil
        jobs[idx].state = .queued
        jobs[idx].progress = 0
        jobs[idx].errorMessage = nil
        jobs[idx].report = nil
        runQueueIfNeeded()
    }

    func delete(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if let url = jobs[idx].outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        deleteSourceImport(jobs[idx])
        if let flags = cancelFlags[jobID] { flags.cancel() }
        removeRecord(jobID: jobID)
        withAnimation { jobs.remove(at: idx) }
        cancelFlags.removeValue(forKey: jobID)
    }

    /// Removes a job's row + record + partial output entirely (used by cancel
    /// and by the watchdogs). Cancelled jobs leave nothing behind.
    private func removeRow(jobID: UUID) {
        cancelFlags.removeValue(forKey: jobID)
        removeRecord(jobID: jobID)
        if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            if let url = jobs[idx].outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            deleteSourceImport(jobs[idx])
            withAnimation { jobs.remove(at: idx) }
        }
    }

    /// "Keep anyway" on a failed-integrity row: the verifier is software and
    /// can produce a false positive (a duration/Sdr-drift mismatch on a
    /// genuinely good encode), but the encode itself is real work the user
    /// must not lose to it. Promotes the scratch file to Documents under a
    /// collision-proof public name and moves the row to Done so Save/Share
    /// work — the report stays attached, still showing what the verifier
    /// found.
    func keepFailedOutput(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[idx].state == .failed,
              let work = jobs[idx].outputURL else { return }
        guard let final = promote(work, sourceName: jobs[idx].sourceName,
                                  preset: jobs[idx].preset) else { return }
        let report = jobs[idx].report
        let name = jobs[idx].sourceName
        let preset = jobs[idx].preset
        jobs[idx].state = .done
        jobs[idx].outputURL = final
        jobs[idx].errorMessage = nil
        noteTerminalTick(.done)
        saveRecord(jobID: jobID, outputName: final.lastPathComponent,
                   report: try? JSONEncoder().encode(report), state: "done")
        // Same storage rule as a normal success: our import copy of the
        // source is no longer needed.
        deleteSourceImport(jobs[idx])
    }

    /// Retires a wedged worker task and starts a fresh one, so the queue can
    /// never be dead-locked by a stuck job.
    private func reviveWorker() {
        workerGeneration += 1   // invalidates the old worker's defer
        workerTask?.cancel()
        workerTask = nil
        runQueueIfNeeded()
    }

    // MARK: Background task (iOS 26+) support

    private func bgSubtitle(_ subtitle: String) {
        if #available(iOS 26.0, *) {
            BackgroundCompress.updateSubtitle(subtitle)
        }
    }

    private func bgProgress(name: String, fraction: Double) {
        if #available(iOS 26.0, *) {
            BackgroundCompress.reportProgress(
                fraction: fraction,
                subtitle: "\(Int(fraction * 100))% · \(name)")
        }
    }

    /// The system is revoking the background task: stop all active engine
    /// work quickly so the task can complete cleanly. Interrupted jobs
    /// become FAILED rows with Retry available (never silently lost).
    func cancelActiveForBackgroundExpiry() {
        for job in jobs where [.analyzing, .compressing, .verifying].contains(job.state) {
            systemInterrupted.insert(job.id)
            cancelFlags[job.id]?.cancel()
        }
    }

    /// Free space on the volume holding `url`, per the "important usage"
    /// policy (conservative about purgeable data). nil when unreadable —
    /// the preflight is best-effort and must never block a healthy disk.
    static func volumeFreeBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
                  forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Storage management

    /// Deletes the app's IMPORT COPY of the source — never anything outside
    /// the Imports folder. After a successful compression the original still
    /// lives in the user's Photos/Files, so keeping our copy would only bloat
    /// the app's "Documents & Data".
    private func deleteSourceImport(_ job: Job) {
        let imports = Self.importsDirectory().standardizedFileURL.path
        let path = job.sourceURL.standardizedFileURL.path
        guard path.hasPrefix(imports + "/") else { return }
        try? FileManager.default.removeItem(at: job.sourceURL)
    }

    /// Bulk variant of deleteSourceImport for the SETUP FLOW: when the user
    /// cancels the sheet (or a batch video was skipped because its probe
    /// failed), the copies that never became jobs would leak in
    /// Caches/Imports until the NEXT launch's sweep — multi-GB on large
    /// batches. Deletes ONLY paths inside the Imports folder; anything the
    /// picker handed us from elsewhere (system temp URLs) is left alone.
    static nonisolated func deleteImportCopies(_ urls: [URL]) {
        let imports = importsDirectory().standardizedFileURL.path
        let fm = FileManager.default
        for url in urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(imports + "/") else { continue }
            try? fm.removeItem(at: url)
        }
    }

    private static var swept = false

    /// Storage sweep at launch: removes orphaned files in Caches/Imports/
    /// (import copies no job needs) and Caches/Working/ (scratch files of
    /// crashed attempts). Outputs in Documents are NEVER swept — files there
    /// that we "don't know about" are the user's (renamed outputs, files
    /// they copied in) and were the data-loss bug.
    ///
    /// - Runs AT MOST ONCE PER PROCESS: loadHistory() can re-fire mid-session
    ///   (.task), and a re-entrant sweep would delete import copies the user
    ///   JUST picked, whose job row doesn't exist yet.
    /// - Skips files that LANDED within the last hour (checked via
    ///   .addedToDirectoryDateKey): copyItem PRESERVES the source's
    ///   modification date, so a fresh copy of an old video looks old by
    ///   mtime and a modification-date cutoff would not protect it.
    /// - Directory detection uses resourceValues(.isDirectoryKey) —
    ///   contentsOfDirectory results don't always carry a reliable
    ///   hasDirectoryPath hint.
    func cleanupOrphans() {
        guard !Self.swept else { return }
        Self.swept = true

        let fm = FileManager.default
        var keepSources = Set<String>()
        for job in jobs where job.state == .failed ||
            [.queued, .analyzing, .compressing, .verifying].contains(job.state) {
            keepSources.insert(job.sourceURL.standardizedFileURL.path)
        }
        // Inbox markers: a stashed import copy can be older than the 1-hour
        // freshness cutoff (copyItem keeps the source mtime); while its
        // marker still exists it MUST count as kept, or the sweep deletes
        // handoff videos waiting for the app to come active.
        keepSources.formUnion(VideoInbox.pendingPaths())
        // Working scratch: in-progress attempts claim \(jobID).mp4; terminal
        // jobs' scratch files are leftovers and disappear.
        var keepWork = Set<String>()
        for job in jobs where [.queued, .analyzing, .compressing, .verifying].contains(job.state) {
            keepWork.insert(Self.workingDirectory()
                .appendingPathComponent("\(job.id.uuidString).mp4")
                .standardizedFileURL.path)
        }

        let cutoff = Date().addingTimeInterval(-3600)
        func sweep(_ dir: URL, keep: Set<String>) {
            guard let files = try? fm.contentsOfDirectory(
                      at: dir,
                      includingPropertiesForKeys: [.isDirectoryKey, .addedToDirectoryDateKey])
            else { return }
            for file in files {
                guard let vals = try? file.resourceValues(
                          forKeys: [.isDirectoryKey, .addedToDirectoryDateKey])
                else { continue }
                if vals.isDirectory == true { continue }        // Inbox staging etc.
                if let added = vals.addedToDirectoryDate, added > cutoff { continue }
                if !keep.contains(file.standardizedFileURL.path) {
                    try? fm.removeItem(at: file)
                }
            }
        }
        sweep(Self.importsDirectory(), keep: keepSources)
        sweep(Self.workingDirectory(), keep: keepWork)
    }

    // MARK: Lazy thumbnails

    /// History rows are rebuilt WITHOUT thumbnails after a relaunch (UIImage
    /// bytes are not persisted in SwiftData). Regenerate lazily when a row
    /// first appears: one bounded AVAssetImageGenerator decode per job,
    /// guarded so a row only ever spawns ONE attempt per process. Prefers
    /// the output file; falls back to the source import (retryable failures
    /// keep theirs).
    func ensureThumbnail(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[idx].thumbnail == nil,
              !thumbnailAttempts.contains(jobID) else { return }
        let url: URL?
        if let out = jobs[idx].outputURL,
           FileManager.default.fileExists(atPath: out.path) {
            url = out
        } else if FileManager.default.fileExists(atPath: jobs[idx].sourceURL.path) {
            url = jobs[idx].sourceURL
        } else {
            url = nil
        }
        guard let url else { return }
        thumbnailAttempts.insert(jobID)
        Task { [weak self] in
            let thumb = await Thumbnails.make(url: url)
            self?.setJob(jobID) { $0.thumbnail = thumb }
        }
    }

    // MARK: SwiftData history

    /// Renames a finished job's output file on disk AND in the history
    /// record, so the new name survives relaunches.
    func renameOutput(jobID: UUID, to newName: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              let out = jobs[idx].outputURL else { return }
        let fm = FileManager.default

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Strip path-hostile characters so the file stays a plain file in
        // Files. `$` is NOT in the list — it is legal in a file name and
        // stripping it rewrote the user's name for no reason.
        let bad = CharacterSet(charactersIn: "/\\:\"?*<>|")
        let clean = trimmed.components(separatedBy: bad).joined(separator: "-")
        let ext = out.pathExtension

        // Determine the STEM (without the extension that is appended below)
        // so the byte-length cap lands before the extension, never inside it.
        var stem = clean
        if !ext.isEmpty {
            if clean.lowercased().hasSuffix("." + ext.lowercased()) {
                // The user included the existing extension — don't double it.
                stem = String(clean.prefix(clean.count - (ext.count + 1)))
            }
        } else if !clean.isEmpty {
            stem = clean
        }
        // A leading dot makes ".foo" a HIDDEN file in Files — prefix so the
        // renamed output stays visible.
        if stem.isEmpty || stem.hasPrefix(".") {
            stem = "Video" + stem
        }
        // NAME_MAX safety: trim BYTE-wise to 150 bytes (CJK names overflow a
        // character count long before 255 bytes), so a long rename can never
        // fail its file move silently.
        while stem.utf8.count > 150 && stem.count > 1 {
            stem = String(stem.dropLast())
        }
        if stem.isEmpty || stem.hasPrefix(".") { stem = "Video" }
        var finalName = ext.isEmpty ? stem : "\(stem).\(ext)"

        // Collide-proof: append "(2)", "(3)"… SKIPPING the file's OWN path —
        // renaming to the same name previously bounced itself to "(2)".
        let original = out.standardizedFileURL.path
        var dst = Self.outputsDirectory().appendingPathComponent(finalName)
        var bump = 1
        while fm.fileExists(atPath: dst.path),
              dst.standardizedFileURL.path != original {
            bump += 1
            let bumpedStem = (finalName as NSString).deletingPathExtension
            dst = Self.outputsDirectory().appendingPathComponent("\(bumpedStem) (\(bump)).\(ext)")
        }
        do {
            try fm.moveItem(at: out, to: dst)
            Self.excludedFromBackup(dst)
        } catch {
            return  // leave the file untouched if the move fails
        }

        jobs[idx].outputURL = dst

        // Update the record's stored file name.
        if let context = modelContext {
            let descriptor = FetchDescriptor<JobRecord>(predicate: #Predicate { $0.jobID == jobID })
            if let r = try? context.fetch(descriptor).first {
                r.outputFileName = dst.lastPathComponent
                try? context.save()
            }
        }
    }

    func loadHistory() {
        guard let context = modelContext else { return }
        let fm = FileManager.default
        // Move any pre-restructure files into their new homes FIRST — rows
        // derive their paths from the directory getters.
        Self.migrateLegacyStorage()
        var out: [Job] = []
        do {
            let descriptor = FetchDescriptor<JobRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            let records = try context.fetch(descriptor)
            // Dedupe robustness: a double-saved record would produce a
            // duplicate row forever (records sort newest-first, so the FIRST
            // occurrence is the newest one and is KEPT; later occurrences
            // are deleted). The first pass collects survivors into `kept` —
            // the old version skipped every jobID that had a duplicate,
            // which hid even the surviving record from history. A SwiftData
            // @Attribute(.unique) constraint was deliberately avoided —
            // adding it to an EXISTING store fails schema migration when
            // duplicates are present.
            var seenJobIDs = Set<UUID>()
            var kept: [JobRecord] = []
            for r in records {
                if seenJobIDs.insert(r.jobID).inserted {
                    kept.append(r)
                } else {
                    context.delete(r)
                }
            }
            if kept.count < records.count { try? context.save() }
            var purgedRecords = false
            for r in kept {
                guard let state = JobState(rawValue: r.stateRaw) else { continue }
                guard state != .queued, state != .analyzing,
                      state != .compressing, state != .verifying else { continue }
                let srcURL = Self.importsDirectory().appendingPathComponent(r.sourceName)
                // Storage management deletes a finished job's source copy, so
                // only RETRYABLE rows (failed) must still have theirs.
                if state == .failed {
                    // A FAILED row is RETRYABLE — without its source it is
                    // junk the user can neither retry nor ever see (every
                    // launch skips it) and it live'd on invisibly. PURGE the
                    // record instead.
                    guard fm.fileExists(atPath: srcURL.path) else {
                        context.delete(r)
                        purgedRecords = true
                        continue
                    }
                }

                var report: IntegrityReport?
                var outputURL: URL?
                if let name = r.outputFileName {
                    let url = Self.outputsDirectory().appendingPathComponent(name)
                    if fm.fileExists(atPath: url.path) {
                        outputURL = url
                        if let data = r.reportJSON {
                            report = try? JSONDecoder().decode(IntegrityReport.self, from: data)
                        }
                    }
                }
                // Decode the REAL preset used for the job (needed for a
                // faithful Retry). Fall back to name-only for old records.
                let realPreset: Preset
                if let data = r.presetJSON, let p = try? JSONDecoder().decode(Preset.self, from: data) {
                    realPreset = p
                } else {
                    realPreset = Preset(name: r.presetName, codec: .hevc, resolution: .keep)
                }
                out.append(Job(
                    id: r.jobID,
                    sourceURL: srcURL,
                    sourceName: r.sourceName,
                    preset: realPreset,
                    state: state,
                    report: report,
                    errorMessage: r.errorMessage,
                    outputURL: outputURL,
                    thumbnail: nil,
                    createdAt: r.createdAt
                ))
            }
            if purgedRecords { try? context.save() }
        } catch {
            // History is best-effort; never block the UI.
        }
        let existingIDs = Set(jobs.map { $0.id })
        jobs.append(contentsOf: out.filter { !existingIDs.contains($0.id) })
        cleanupOrphans()
    }

    private func saveRecord(jobID: UUID, outputName: String?, report: Data?, state: String, errorText: String? = nil) {
        guard let context = modelContext else { return }
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[idx]

        // Remove an older record for retries.
        removeRecord(jobID: jobID)

        var outBytes: Int64 = 0
        if let name = outputName {
            let p = Self.outputsDirectory().appendingPathComponent(name)
            outBytes = ((try? FileManager.default.attributesOfItem(atPath: p.path))?[.size] as? Int64) ?? 0
        }
        var inBytes: Int64 = 0
        if let plan = job.plan {
            inBytes = plan.source.fileSize
        } else {
            inBytes = ((try? FileManager.default.attributesOfItem(atPath: job.sourceURL.path))?[.size] as? Int64) ?? 0
        }

        let record = JobRecord(
            jobID: jobID,
            createdAt: job.createdAt,
            sourceName: job.sourceName,
            presetName: job.preset.name,
            outputFileName: outputName,
            inBytes: inBytes,
            outBytes: outBytes,
            duration: job.plan?.duration ?? 0,
            stateRaw: state,
            errorMessage: errorText,
            reportJSON: report,
            presetJSON: try? JSONEncoder().encode(job.preset),
            codecLabel: job.preset.codec.displayName,
            resolutionLabel: job.preset.resolution.displayName
        )
        context.insert(record)
        try? context.save()
    }

    private func removeRecord(jobID: UUID) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<JobRecord>(predicate: #Predicate { $0.jobID == jobID })
        if let records = try? context.fetch(descriptor) {
            for r in records { context.delete(r) }
            try? context.save()
        }
    }

    // MARK: helpers

    private func setJob(_ jobID: UUID, _ mutate: (inout Job) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        // Tick only on an actual STATE change: setJob runs after every
        // mutation, and a late progress update on an already-finished job
        // re-ticked the terminal haptic (a phantom success buzz per stale
        // engine emission).
        let oldState = jobs[idx].state
        mutate(&jobs[idx])
        if jobs[idx].state != oldState {
            noteTerminalTick(jobs[idx].state)
        }
    }

    /// Haptic ticks for terminal transitions. The old per-row
    /// `.sensoryFeedback(trigger: stateTrigger)` never fired reliably: a
    /// terminal row MOVES between the active/finished ForEachs, so the row
    /// view is rebuilt after the transition and the change is never
    /// observes inside it. The ticks live on the COORDINATOR (published,
    /// process-wide) and RootView attaches the feedback once. Cancellations
    /// deliberately don't tick — the user did that themselves.
    @Published var completionTick = 0
    @Published var failureTick = 0

    private func noteTerminalTick(_ state: JobCoordinator.JobState) {
        switch state {
        case .done: completionTick += 1
        case .failed: failureTick += 1
        default: break
        }
    }

    private func presetStamp(_ preset: Preset) -> String {
        let raw = preset.name.lowercased()
        let words = raw.split(separator: " ", omittingEmptySubsequences: true)
            .prefix(2).joined(separator: "-")
        let cleaned = words.replacingOccurrences(of: "[^a-z0-9-]", with: "",
                                                 options: .regularExpression)
        // Non-Latin preset names (Arabic, Persian, Chinese, …) strip to an
        // empty stamp here. The fallback is built from the preset's VALUES
        // so the user can still tell which preset produced which file
        // (resolution + bitrate appear right in the name) instead of a
        // useless pile of video_preset.mp4, video_preset (2).mp4, …
        // The codec family rides along in every stamp: users producing both
        // HEVC and H.264 variants of the same source can tell the files
        // apart in Files without opening them.
        let codecTag = "-\(preset.codec.rawValue)"
        if cleaned.isEmpty {
            let fallback = "\(preset.resolution.rawValue)-\(String(format: "%.1f", preset.fixedBitrateMbps))mbps"
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9-]", with: "-",
                                      options: .regularExpression)
            return (fallback.isEmpty ? "preset" : fallback) + codecTag
        }
        return cleaned + codecTag
    }

    /// First output path not taken on disk: `name_stamp.mp4`, then
    /// `name_stamp (2).mp4`, `(3)`, … The name is COLLISION-PROOF exactly
    /// like renameOutput — no output is ever overwritten, so two jobs with
    /// the same source + preset (or a hyphenated name bisecting into another
    /// job's base) can never destroy each other's files.
    static func uniqueOutputURL(in dir: URL, base: String, stamp: String) -> URL {
        let fm = FileManager.default
        let stem = "\(base)_\(stamp)"
        var url = dir.appendingPathComponent("\(stem).mp4")
        var bump = 1
        while fm.fileExists(atPath: url.path) {
            bump += 1
            url = dir.appendingPathComponent("\(stem) (\(bump)).mp4")
        }
        return url
    }

    /// Shared SUCCESS-ONLY promotion: move a verified scratch file into
    /// Documents under its collision-proof public name (same volume → a
    /// cheap rename). Returns nil when the move fails — callers must treat
    /// that as a failure, not a "done with the file in scratch" (the sweep
    /// erases scratch and the record would lie about it).
    private func promote(_ work: URL, sourceName: String, preset: Preset) -> URL? {
        let fm = FileManager.default
        let outDir = Self.outputsDirectory()
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        // NAME_MAX safety: a long source name can push the base+stamp file
        // name past the 255-byte path-component limit and make the move
        // fail; trim the base so the full name always fits.
        let base = String((sourceName as NSString).deletingPathExtension.prefix(100))
        let final = Self.uniqueOutputURL(in: outDir, base: base, stamp: presetStamp(preset))
        do {
            try fm.moveItem(at: work, to: final)
            Self.excludedFromBackup(final)
            return final
        } catch {
            return nil
        }
    }

    static nonisolated func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static nonisolated func cachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// Compressed outputs live DIRECTLY in Documents (the folder exposed in
    /// Files → On My iPad), so the user sees just their finished videos.
    static nonisolated func outputsDirectory() -> URL {
        documentsDirectory()
    }

    /// Outputs in Documents are included in iCloud device backups by
    /// default — several GB of videos would silently eat the user's backup
    /// quota while the originals still live in Photos/Files. Set the
    /// exclusion on every promoted (or renamed) output file.
    static func excludedFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    /// Import copies live in Caches/Imports — the Files app doesn't show the
    /// caches folder, so pending sources never clutter "On My iPad".
    /// (Caches can be purged by the system under storage pressure, but every
    /// import here belongs to a pending/failed job we'd happily retry from
    /// the original library selection anyway.)
    static nonisolated func importsDirectory() -> URL {
        cachesDirectory().appendingPathComponent("Imports", isDirectory: true)
    }

    /// Scratch space for IN-PROGRESS encodes — Caches/Working. A run encodes
    /// AND verifies its file here and renames it into Documents only on
    /// SUCCESS, so a crash or kill mid-write leaves partial output where the
    /// user can never see it (the launch sweep erases leftovers of dead
    /// attempts). Same volume as Documents → the success move is a cheap
    /// rename, not a copy.
    static nonisolated func workingDirectory() -> URL {
        cachesDirectory().appendingPathComponent("Working", isDirectory: true)
    }

    /// One-time move from the old layout (Documents/Compressed + Documents/Imports)
    /// to the new one (outputs at Documents root, imports in Caches/Imports).
    /// MUST run before loadHistory() builds rows — paths are derived from the
    /// directory getters, so files must be in their new homes first.
    static func migrateLegacyStorage() {
        let fm = FileManager.default

        let legacyOutputs = documentsDirectory().appendingPathComponent("Compressed", isDirectory: true)
        if fm.fileExists(atPath: legacyOutputs.path) {
            for file in (try? fm.contentsOfDirectory(at: legacyOutputs, includingPropertiesForKeys: nil)) ?? [] {
                let dst = documentsDirectory().appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try? fm.moveItem(at: file, to: dst)
            }
            try? fm.removeItem(at: legacyOutputs)
        }

        let legacyImports = documentsDirectory().appendingPathComponent("Imports", isDirectory: true)
        if fm.fileExists(atPath: legacyImports.path) {
            try? fm.createDirectory(at: importsDirectory(), withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: legacyImports, includingPropertiesForKeys: nil)) ?? [] {
                let dst = importsDirectory().appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try? fm.moveItem(at: file, to: dst)
            }
            try? fm.removeItem(at: legacyImports)
        }
    }
}
