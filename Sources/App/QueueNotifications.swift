import UIKit
import UserNotifications

/// Local notifications for the QUEUE-DRAINED event. A queue that finishes
/// while the app is backgrounded is otherwise invisible: the background
/// continuation keeps the process alive until the last job goes terminal,
/// then the user deserves a banner (and tapping it reopens the app).
enum QueueNotifications {
    /// Best-effort authorization, asked on the FIRST enqueue (never at
    /// launch — no unprompted system dialogs over an empty screen). Already
    /// granted/denied states are left exactly as they are.
    static func ensureAuthorized() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func queueFinished(success: Bool, name: String, detail: String?) {
        let content = UNMutableNotificationContent()
        content.title = success ? "Compression finished" : "Compression failed"
        if success {
            content.body = "“\(name)” is ready. Open VidCompress to see the integrity report."
        } else {
            content.body = "“\(name)” failed\(detail.map { ": \($0)" } ?? ""). Open VidCompress to retry."
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)   // fire immediately
        UNUserNotificationCenter.current().add(request)
    }
}
