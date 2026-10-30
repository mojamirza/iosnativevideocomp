import Foundation
import SwiftUI
import SwiftData
import AVFoundation

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
    }

    @Published var jobs: [Job] = []

    private var workerTask: Task<Void, Never>?
    /// Bumped every time a worker is spawned or retired, so a late-waking old
    /// worker's `defer` can't nil out a NEW worker's task reference.
    private var workerGeneration = 0
    private var cancelFlags: [UUID: EngineFlags] = [:]
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

    /// Starts driving the queue. On iOS 26+ a BGContinuedProcessingTask keeps
    /// the app alive in the background while jobs run (with progress on the
    /// system's Lock Screen indicator); on older systems the plain in-app
    /// worker task runs the queue while the app is open.
    private func runQueueIfNeeded() {
        guard workerTask == nil else { return }
        if #available(iOS 26.0, *) {
            if BackgroundCompress.isRegistered {
                // A live BG driver picks up newly queued jobs by itself.
                if BackgroundCompress.isRunning { return }
                let queued = jobs.filter { $0.state == .queued }
                guard !queued.isEmpty else { return }
                let subtitle = queued.count == 1
                    ? queued[0].sourceName
                    : "\(queued.count) videos"
                if BackgroundCompress.submit(subtitle: subtitle) {
                    scheduleBackgroundLivenessCheck()
                    return
                }
                // Submission refused → fall through to the in-app worker.
            }
        }
        startForegroundWorker()
    }

    /// The in-app fallback worker (used when BG tasks are unavailable).
    private func startForegroundWorker() {
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
                      let idx = self.jobs.firstIndex(where: { $0.state == .queued }) else { break }
                // Claim the job atomically (MainActor) BEFORE running it, so a
                // revived second worker can never double-process the same job.
                self.jobs[idx].state = .analyzing
                let id = self.jobs[idx].id
                await self.run(jobID: id)
            }
        }
    }

    /// Safety net: if the system accepted the submission but never starts the
    /// task, fall back to the in-app worker so queued jobs don't strand. The
    /// BG driver defers to a live foreground worker, so even a late handler
    /// start can't cause double processing.
    private func scheduleBackgroundLivenessCheck() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self,
                  self.workerTask == nil,
                  !BackgroundCompress.isRunning,
                  self.jobs.contains(where: { $0.state == .queued }) else { return }
            self.startForegroundWorker()
        }
    }

    func run(jobID: UUID) async {
        // The queue claim already moved this job out of .queued; if a watchdog
        // force-finished it in the meantime, do nothing (never re-run a job
        // that reached a terminal state).
        guard let job = jobs.first(where: { $0.id == jobID }),
              ![JobState.done, .failed, .cancelled].contains(job.state) else { return }
        let flags = EngineFlags()
        cancelFlags[jobID] = flags

        let fm = FileManager.default
        let outDir = Self.outputsDirectory()
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let base = (job.sourceName as NSString).deletingPathExtension
        var ext = (job.sourceName as NSString).pathExtension
        if ext.isEmpty { ext = "mp4" }
        let output = outDir.appendingPathComponent("\(base)_\(presetStamp(job.preset)).\(ext)")
        try? fm.removeItem(at: output)

        // analyzing
        setJob(jobID) { $0.state = .analyzing }
        bgSubtitle("Analysing \(job.sourceName)…")
        let encodeStart = Date()

        do {
            let plan: OptimizerPlan
            if let p = job.plan {
                plan = p
            } else {
                let probe = try await ProbeResult.probe(url: job.sourceURL)
                plan = QualitySizeOptimizer.plan(preset: job.preset, probe: probe)
                setJob(jobID) { $0.plan = plan }
            }

            setJob(jobID) {
                $0.state = .compressing
                $0.progress = 0
            }
            bgSubtitle("Encoding \(job.sourceName)…")

            // Backstop for the whole encode: the engine has its own watchdog,
            // but if anything wedges the WORKER, this independent task fails
            // the row and revives the queue. The queue can never stay dead.
            let compressDeadline = max(240, plan.duration * 6 + 120)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(compressDeadline * 1_000_000_000))
                self?.forceCompressTerminal(jobID: jobID)
            }

            try await CompressionEngine.compress(
                source: job.sourceURL,
                output: output,
                preset: job.preset,
                plan: plan,
                flags: flags
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.setJob(jobID) { $0.progress = progress }
                    self?.bgProgress(name: job.sourceName, fraction: progress)
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
            let verifyDeadline = Date()
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
            let reportData = try? JSONEncoder().encode(report)

            setJob(jobID) {
                $0.state = report.passed ? .done : .failed
                $0.report = report
                $0.outputURL = output
                if !report.passed {
                    $0.errorMessage = "Output integrity report failed — see details."
                }
            }
            // A cancel that landed during verification: honour it — remove
            // the row entirely instead of reporting a finished file.
            if flags.cancelled {
                removeRow(jobID: jobID)
                try? await Task.sleep(nanoseconds: 200_000_000)
                return
            }
            saveRecord(jobID: jobID, outputName: output.lastPathComponent,
                       report: reportData, state: report.passed ? "done" : "failed")
            // Storage management: a finished job doesn't need our copy of the
            // source anymore — the original still lives in Photos/Files.
            if report.passed {
                deleteSourceImport(job)
            }

        } catch is CancellationError {
            // Cancelled jobs leave no trace: no row, no record, no partial file.
            removeRow(jobID: jobID)
        } catch CompressionError.cancelled {
            removeRow(jobID: jobID)
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

    /// Watchdog backstop for the ENCODE phase: only acts if the job is still
    /// in .compressing (the engine's own watchdog fires earlier). Fails the
    /// row and revives the queue.
    private func forceCompressTerminal(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[idx].state == .compressing else { return }
        setJob(jobID) {
            $0.state = .failed
            $0.errorMessage = "Encoding stalled and was aborted."
        }
        saveRecord(jobID: jobID, outputName: nil, report: nil, state: "failed",
                   errorText: "Encoding stalled and was aborted.")
        cancelFlags.removeValue(forKey: jobID)
        reviveWorker()
    }

    /// Watchdog backstop for the VERIFY phase: only acts if the job is STILL
    /// in .verifying (the normal path finishes in ≤60 s and has already moved
    /// the row on).
    private func forceVerifyTerminal(jobID: UUID, output: URL, encodeSeconds: Double, startedAt: Date) {
        guard Date().timeIntervalSince(startedAt) >= 74 else { return }
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[idx].state == .verifying else { return }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int64) ?? 0
        let report = IntegrityReport(
            items: [ReportItem("verify", "Verification timed out",
                "The integrity checks took too long and were stopped. The output file was finalized by the encoder — if it plays in Files, it is good.", .warn)],
            inBytes: jobs[idx].plan?.source.fileSize ?? 0,
            outBytes: fileSize,
            outputBitrateMbps: 0,
            encodeSeconds: encodeSeconds,
            outputDuration: 0)
        jobs[idx].state = .done
        jobs[idx].report = report
        jobs[idx].outputURL = output
        saveRecord(jobID: jobID, outputName: output.lastPathComponent,
                   report: try? JSONEncoder().encode(report), state: "done")
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
            // Never started — just drop it.
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
    /// work quickly so the task can complete cleanly. Cancelled jobs leave
    /// no trace, consistent with in-app cancel semantics.
    func cancelActiveForBackgroundExpiry() {
        for job in jobs where [.analyzing, .compressing, .verifying].contains(job.state) {
            cancelFlags[job.id]?.cancel()
        }
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

    /// Storage sweep at launch: removes any file in Imports/ or Compressed/
    /// that no remaining job references — crash leftovers and artifacts from
    /// older app versions. Sources are kept only while a job could still be
    /// retried (failed/active); outputs are kept while a record shows them.
    func cleanupOrphans() {
        let fm = FileManager.default
        var keep = Set<String>()
        for job in jobs {
            if job.state == .failed ||
               [.queued, .analyzing, .compressing, .verifying].contains(job.state) {
                keep.insert(job.sourceURL.standardizedFileURL.path)
            }
            if let out = job.outputURL {
                keep.insert(out.standardizedFileURL.path)
            }
        }
        for dir in [Self.importsDirectory(), Self.outputsDirectory()] {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where !keep.contains(file.standardizedFileURL.path) {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: SwiftData history

    func loadHistory() {
        guard let context = modelContext else { return }
        let fm = FileManager.default
        var out: [Job] = []
        do {
            let descriptor = FetchDescriptor<JobRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            let records = try context.fetch(descriptor)
            for r in records {
                guard let state = JobState(rawValue: r.stateRaw) else { continue }
                guard state != .queued, state != .analyzing,
                      state != .compressing, state != .verifying else { continue }
                let srcURL = Self.importsDirectory().appendingPathComponent(r.sourceName)
                // Storage management deletes a finished job's source copy, so
                // only RETRYABLE rows (failed) must still have theirs.
                if state == .failed {
                    guard fm.fileExists(atPath: srcURL.path) else { continue }
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
            codecLabel: job.preset.codec.rawValue,
            resolutionLabel: job.preset.resolution.rawValue
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
        mutate(&jobs[idx])
    }

    private func presetStamp(_ preset: Preset) -> String {
        let raw = preset.name.lowercased()
        let words = raw.split(separator: " ", omittingEmptySubsequences: true)
            .prefix(2).joined(separator: "-")
        return words.replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    }

    static nonisolated func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static nonisolated func outputsDirectory() -> URL {
        documentsDirectory().appendingPathComponent("Compressed", isDirectory: true)
    }

    static nonisolated func importsDirectory() -> URL {
        documentsDirectory().appendingPathComponent("Imports", isDirectory: true)
    }
}
