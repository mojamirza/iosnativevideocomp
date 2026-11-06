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
        .commands {
            AppMenuCommands(coordinator: coordinator)
        }
    }
}

/// Menu bar for iPadOS 26 windowed mode (and keyboard shortcuts with any
/// hardware keyboard): File / Queue / Help menus beside the system menus.
/// Menu items flip one-shot request flags on the coordinator; RootView
/// owns the sheets and dialogs they trigger.
struct AppMenuCommands: Commands {
    // ObservedObject: menu items (disabled states, labels) must refresh when
    // the coordinator's published state changes — a plain let never updates.
    @ObservedObject var coordinator: JobCoordinator

    var body: some Commands {
        // NOTE: no menu named "File" — iPadOS does NOT merge a custom
        // "File" menu with the system one (it shows both), which produced
        // a duplicate section. Unique menu names only. Same story for
        // "Help": items go INTO the system Help menu via CommandGroup.
        CommandMenu("Import") {
            Button("Import from Files…") {
                coordinator.requestFilesImport = true
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("New Preset…") {
                coordinator.requestPresetEditor = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Queue") {
            Button("Cancel Active Job") {
                coordinator.cancelActiveJob()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!coordinator.hasActiveJob)
            Button("Cancel All Jobs") {
                coordinator.cancelAllJobs()
            }
            .disabled(!coordinator.hasActiveJob && !coordinator.hasQueuedJob)
            Divider()
            Button("Clear Finished…") {
                coordinator.requestClearFinished = true
            }
            .disabled(!coordinator.jobs.contains { [.done, .failed, .cancelled].contains($0.state) })
        }
        CommandGroup(after: .help) {
            Button("About & Settings…") {
                coordinator.requestSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Link("Project Page", destination: URL(string: "https://github.com/mojamirza/iosnativevideocomp")!)
        }
    }
}
