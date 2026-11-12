import Foundation
import BackgroundTasks

/// Thread-safe expiry flag: the expiration handler runs off the main actor.
final class BGExpiryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    var isExpired: Bool {
        lock.lock(); defer { lock.unlock() }; return expired
    }
    func set() {
        lock.lock(); expired = true; lock.unlock()
    }
}

/// Background compression (iOS 26+): keeps encodes ALIVE after the user
/// leaves the app, with progress surfaced on the system's Lock Screen
/// indicator.
///
/// Design (the in-app worker is always the foreground executor):
/// - A compression starts INSTANTLY in the in-app worker — no wait for the
///   system to spin up the BG task.
/// - The BG task is submitted at job start as a background LIFELINE: its
///   handler waits while the in-app worker owns the work, then sweeps any
///   still-queued jobs and completes. Because the task stays ongoing for the
///   whole queue, the system does not suspend the app mid-encode.
/// - If the system revokes the task, active work is stopped and the jobs are
///   marked FAILED with Retry available (never silently lost).
/// - If the task can't be used at all (submission refused — e.g. sideloaded
///   profiles, background refresh disabled), everything still works in the
///   foreground exactly like before.
@available(iOS 26.0, *)
@MainActor
enum BackgroundCompress {

    /// Must match BGTaskSchedulerPermittedIdentifiers in the Info.plist.
    static let taskID = "com.example.vidcompress.compress"

    private static weak var coordinator: JobCoordinator?
    private static var currentTask: BGContinuedProcessingTask?

    private(set) static var isRegistered = false
    static var isRunning: Bool { currentTask != nil }

    /// Called once at launch, before any submission can happen.
    /// `BGTaskScheduler.register` returns a Bool — false when the
    /// identifier is missing from BGTaskSchedulerPermittedIdentifiers
    /// (the classic re-sign cause) or it was called twice. A refused
    /// registration previously still set isRegistered = true, so the
    /// launch-resume gate submitted a task that could only throw.
    /// isRegistered now records the truth; JobCoordinator surfaces the
    /// same one-time "background unavailable" notice a refused submit
    /// would have produced.
    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let expiry = BGExpiryFlag()
            continued.expirationHandler = {
                expiry.set()
                Task { @MainActor in
                    BackgroundCompress.systemIsRevokingTask()
                }
            }
            Task { @MainActor in
                BackgroundCompress.drive(continued, expiry: expiry)
            }
        }
        if ok {
            isRegistered = true
        } else {
            NSLog("VidCompress: BGTaskScheduler refused registration for \(taskID) — background continuation is unavailable this session.")
        }
    }

    /// Called once the UI has created its coordinator.
    static func attach(coordinator: JobCoordinator) {
        self.coordinator = coordinator
    }

    /// Submits a user-initiated continued-processing task. Returns false when
    /// the system refuses (unsupported, profile without the capability,
    /// background refresh off, …) — purely informational: the in-app worker
    /// is always already running when this is called.
    private static var submitPending = false
    /// When submit() raised the flag. A submitted request whose handler
    /// never fires (schedule lost it, task ID mismatch) must not lock the
    /// flag on for the whole session — it goes stale after 60 s.
    private static var submitPendingSince = Date.distantPast
    static func submit(subtitle: String) -> Bool {
        // Already requested and not started yet: treat as success instead of
        // double-submitting (the second submit throws and would wrongly
        // surface the "background unavailable" alert). Stale requests (60 s
        // without the handler firing) don't count as started.
        if submitPending,
           Date().timeIntervalSince(submitPendingSince) < 60 {
            return true
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: taskID,
            title: "Compressing videos",
            subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            submitPending = true
            submitPendingSince = Date()
            return true
        } catch {
            return false
        }
    }

    /// Drives the queue for the lifetime of one BG task.
    private static func drive(_ task: BGContinuedProcessingTask, expiry: BGExpiryFlag) {
        // ONE driver loop at a time: a second delivered task (e.g. after the
        // 60 s stale-submitPending path allows a re-submit) would claim a
        // different queued job and run TWO encodes concurrently — the
        // foreground worker is parked while a BG task runs. The running
        // loop already sweeps the whole queue; refuse the duplicate.
        guard currentTask == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        currentTask = task
        task.progress.totalUnitCount = 100
        updateSubtitle("Working…")
        Task { @MainActor in
            // The pending flag resets HERE, on the main actor: the register
            // handler may run on a non-main queue, and under strict
            // concurrency a mutable static write from there is a hazard.
            // A delivered request also might never drive this loop (expired,
            // refused), so the flag must drop before the sweep starts.
            submitPending = false
            submitPendingSince = .distantPast
            while !expiry.isExpired {
                guard let coordinator else { break }
                // A background-task REVOCATION pauses the queue: the
                // coordinator cancels the active encode for a revoked task.
                if coordinator.bgPaused { break }
                // The in-app worker is the foreground executor (instant
                // start). While it's alive it owns the work — wait for it to
                // finish, then sweep anything still queued. The task staying
                // ongoing is what keeps the app unsuspended mid-encode.
                if coordinator.foregroundWorkerActive {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                // Same pick rule as the in-app worker: the array is newest-
                // first, so the LAST queued entry is the OLDEST pick (FIFO
                // by selection order).
                guard let idx = coordinator.jobs.lastIndex(where: { $0.state == .queued }) else { break }
                coordinator.jobs[idx].state = .analyzing
                let id = coordinator.jobs[idx].id
                await coordinator.run(jobID: id)
            }
            // A FOREGROUND revocation strands the queue: the driver exits on
            // expiry while bgPaused stays false (the pause path only covers
            // a BACKGROUNDED revocation, whose recovery is the scenePhase
            // .active transition — a transition that never comes while the
            // app is already active). Hand the queue back to the foreground
            // worker: currentTask must clear FIRST so startForegroundWorker
            // is not refused by the isRunning gate. The backgrounded exit
            // keeps its existing recovery (bgPaused guards the worker) and
            // does not submit while suspended.
            currentTask = nil
            if let coordinator, !coordinator.bgPaused,
               coordinator.jobs.contains(where: { $0.state == .queued }) {
                coordinator.runQueueIfNeeded()
            }
            task.setTaskCompleted(success: !expiry.isExpired)
        }
    }

    /// The system is taking the task away (runtime limit / pressure): stop
    /// active engine work quickly so the task can complete. Interrupted jobs
    /// become FAILED rows with Retry available — never silently lost.
    private static func systemIsRevokingTask() {
        coordinator?.cancelActiveForBackgroundExpiry()
        updateSubtitle("Interrupted — reopen VidCompress to continue")
    }

    static func reportProgress(fraction: Double, subtitle: String) {
        guard let task = currentTask else { return }
        task.progress.completedUnitCount = Int64((max(0, min(1, fraction)) * 100).rounded())
        task.updateTitle("Compressing videos", subtitle: subtitle)
    }

    static func updateSubtitle(_ subtitle: String) {
        guard let task = currentTask else { return }
        task.updateTitle("Compressing videos", subtitle: subtitle)
    }
}
