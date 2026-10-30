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
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
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
        isRegistered = true
    }

    /// Called once the UI has created its coordinator.
    static func attach(coordinator: JobCoordinator) {
        self.coordinator = coordinator
    }

    /// Submits a user-initiated continued-processing task. Returns false when
    /// the system refuses (unsupported, profile without the capability,
    /// background refresh off, …) — purely informational: the in-app worker
    /// is always already running when this is called.
    static func submit(subtitle: String) -> Bool {
        let request = BGContinuedProcessingTaskRequest(
            identifier: taskID,
            title: "Compressing videos",
            subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    /// Drives the queue for the lifetime of one BG task.
    private static func drive(_ task: BGContinuedProcessingTask, expiry: BGExpiryFlag) {
        currentTask = task
        task.progress.totalUnitCount = 100
        updateSubtitle("Working…")
        Task { @MainActor in
            while !expiry.isExpired {
                guard let coordinator else { break }
                // The in-app worker is the foreground executor (instant
                // start). While it's alive it owns the work — wait for it to
                // finish, then sweep anything still queued. The task staying
                // ongoing is what keeps the app unsuspended mid-encode.
                if coordinator.foregroundWorkerActive {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                guard let idx = coordinator.jobs.firstIndex(where: { $0.state == .queued }) else { break }
                coordinator.jobs[idx].state = .analyzing
                let id = coordinator.jobs[idx].id
                await coordinator.run(jobID: id)
            }
            // No awaits from here to completion — the enqueue path can't
            // interleave on the main actor, so no queued job is stranded.
            currentTask = nil
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
