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

    private func runQueueIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task {
            defer { self.workerTask = nil }
            while !Task.isCancelled {
                guard let idx = jobs.firstIndex(where: { $0.state == .queued }) else { break }
                let id = jobs[idx].id
                await run(jobID: id)
            }
        }
    }

    private func run(jobID: UUID) async {
        guard jobs.contains(where: { $0.id == jobID }) else { return }
        let job = jobs.first { $0.id == jobID }!
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

            try await CompressionEngine.compress(
                source: job.sourceURL,
                output: output,
                preset: job.preset,
                plan: plan,
                flags: flags
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.setJob(jobID) { $0.progress = progress }
                }
            }

            setJob(jobID) {
                $0.state = .verifying
                $0.progress = 1.0
            }

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
            saveRecord(jobID: jobID, outputName: output.lastPathComponent,
                       report: reportData, state: report.passed ? "done" : "failed")

        } catch is CancellationError {
            setJob(jobID) { $0.state = .cancelled; $0.errorMessage = "Cancelled." }
            saveRecord(jobID: jobID, outputName: nil, report: nil, state: "cancelled")
        } catch CompressionError.cancelled {
            setJob(jobID) { $0.state = .cancelled; $0.errorMessage = "Cancelled." }
            saveRecord(jobID: jobID, outputName: nil, report: nil, state: "cancelled")
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

    /// Watchdog backstop: only acts if the job is STILL in .verifying (the
    /// normal path finishes in ≤60 s and has already moved the row on).
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
    }

    // MARK: Actions

    func cancel(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[idx].state == .queued {
            jobs.remove(at: idx)
        } else if let flags = cancelFlags[jobID] {
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
        if let flags = cancelFlags[jobID] { flags.cancel() }
        removeRecord(jobID: jobID)
        jobs.remove(at: idx)
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
                guard state != .queued, state != .analyzing, state != .compressing else { continue }
                let srcURL = Self.importsDirectory().appendingPathComponent(r.sourceName)
                guard fm.fileExists(atPath: srcURL.path) else { continue }

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
