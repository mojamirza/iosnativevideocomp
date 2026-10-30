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

/// Background compression (iOS 26+): the job queue is driven by a
/// BGContinuedProcessingTask, so encodes KEEP RUNNING after the user leaves
/// the app, with progress surfaced on the system's Lock Screen indicator.
///
/// Design:
/// - The scheduler handler is registered once at launch (App.init) — required
///   before any submission. The JobCoordinator is attached when the UI is
///   ready (RootView.task).
/// - The BG task is the PRIMARY driver of the queue. If it can't be used
///   (older iOS, refused submission) the coordinator falls back to its in-app
///   foreground worker. The two drivers never run at the same time: the BG
///   driver defers to a live foreground worker and completes immediately.
/// - Submission happens from enqueue/retry — user actions, as the API
///   requires ("submission needs to occur as a result of a person's action").
/// - If the system expires the task mid-encode, active engine work is
///   cancelled quickly (cancelled jobs leave no trace) and the task
///   completes cleanly — the app is never suspended mid-write.
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
    /// the system refuses (unsupported, too many ongoing tasks, …) so the
    /// caller can fall back to the in-app worker.
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
        updateSubtitle("Preparing…")
        Task { @MainActor in
            while !expiry.isExpired {
                guard let coordinator else { break }
                // Never compete with the in-app foreground worker (fallback
                // path) — it owns the queue while alive.
                if coordinator.foregroundWorkerActive { break }
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
    /// active engine work fast so the task can complete. Cancelled jobs
    /// leave no trace, consistent with in-app cancel semantics.
    private static func systemIsRevokingTask() {
        coordinator?.cancelActiveForBackgroundExpiry()
        updateSubtitle("Stopped — reopen VidCompress to compress again")
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
