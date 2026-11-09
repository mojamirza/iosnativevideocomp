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
            // the app). The flag turns that into a visible banner, and the
            // log keeps the ORIGINAL error for triage (why did the open
            // fail — disk full, corrupt WAL, permissions?).
            StorageFallback.inMemoryOnly = true
            NSLog("VidCompress: opening the SwiftData store failed (\(error)) — falling back to an in-memory container. History is unavailable this session; the launch sweep is disabled.")
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
            AppMenuCommands(menuState: coordinator.menuState, coordinator: coordinator)
        }
    }
}

/// Menu bar for iPadOS 26 windowed mode (and keyboard shortcuts with any
/// hardware keyboard): File / Queue / Help menus beside the system menus.
/// Menu items flip one-shot request flags on the coordinator; RootView
/// owns the sheets and dialogs they trigger.
struct AppMenuCommands: Commands {
    // Menu items observe the LIGHTWEIGHT QueueMenuState snapshot — progress
    // ticks never reach the menus (the old direct observation made the menu
    // bar tick every update).
    @ObservedObject var menuState: QueueMenuState
    let coordinator: JobCoordinator

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
            .disabled(!menuState.hasActive)
            Button("Cancel All Jobs") {
                coordinator.cancelAllJobs()
            }
            .disabled(!menuState.hasActive && !menuState.hasQueued)
            Divider()
            Button("Clear Finished…") {
                coordinator.requestClearFinished = true
            }
            .disabled(!menuState.hasFinished)
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
