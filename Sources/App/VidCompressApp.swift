import SwiftUI
import SwiftData

/// Raised ONCE in App.init when the SwiftData document store could not be
/// opened and the app fell back to an IN-MEMORY container. The root banner
/// reads it as a stable per-process value.
enum StorageFallback {
    static var inMemoryOnly = false
}

@main
struct VidCompressApp: App {
    private let container: ModelContainer

    @StateObject private var coordinator: JobCoordinator

    init() {
        do {
            container = try ModelContainer(for: JobRecord.self)
        } catch {
            // Fall back to an in-memory store if the document store is
            // corrupt — the previous silent fallback made HISTORY vanish
            // with no explanation (records written this session die with
            // the app). The flag turns that into a visible banner.
            StorageFallback.inMemoryOnly = true
            container = try! ModelContainer(
                for: JobRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        // The SwiftData context is attached later from RootView (modelContext
        // is MainActor-isolated and must not be captured in this autoclosure).
        // Register the background-compression task (iOS 26+) at launch, as
        // BGTaskScheduler requires. App.init runs on the main thread.
        if #available(iOS 26.0, *) {
            MainActor.assumeIsolated {
                BackgroundCompress.register()
            }
        }
        _coordinator = StateObject(wrappedValue: JobCoordinator())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
        }
        .modelContainer(container)
    }
}
