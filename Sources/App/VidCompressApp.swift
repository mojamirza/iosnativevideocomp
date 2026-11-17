import SwiftUI
import SwiftData

/// Raised ONCE in App.init when the SwiftData document store could not be
/// opened. `inMemoryOnly` marks the last-resort memory-only session (the
/// root banner reads both as stable per-process values). `storeReset` marks
/// the RECOVERY path: the unopenable store was quarantined and a fresh
/// on-disk store created — history persists this session and later ones;
/// the old data lives in the kept backup file.
enum StorageFallback {
    static var inMemoryOnly = false
    static var storeReset = false
}

@main
struct VidCompressApp: App {
    private let container: ModelContainer

    @StateObject private var coordinator: JobCoordinator

    init() {
        do {
            container = try ModelContainer(for: JobRecord.self)
        } catch {
            // P1: the on-disk store is UNOPENABLE — a schema change the old
            // file cannot migrate (the failure mode a non-optional field
            // added later produces: JobRecord must only ever gain fields
            // that are optional or defaulted), or plain corruption. The
            // previous fallback — in-memory — made the app RUN but
            // silently wrecked history: records written this session died
            // with the process, AND the broken store stayed broken forever
            // (every relaunch repeated the fallback; history looked wiped
            // with no recovery in sight).
            //
            // RECOVERY: quarantine the unopenable file (KEPT, never
            // deleted — triage and manual salvage remain possible) and
            // open a FRESH on-disk store, so this session's history
            // persists across relaunches like normal. The reset is
            // announced by the store-reset banner (storeReset flag).
            let support = URL.applicationSupportDirectory
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let broken = support.appendingPathComponent("default.store\(suffix)")
                let kept = support.appendingPathComponent(
                    "default.store.broken-\(stamp)\(suffix)")
                try? FileManager.default.moveItem(at: broken, to: kept)
            }
            do {
                container = try ModelContainer(for: JobRecord.self)
                StorageFallback.storeReset = true
                NSLog("VidCompress: the SwiftData store was unopenable (\(error)) — quarantined as default.store.broken-\(stamp)* and a fresh store was created. Old history is kept in the quarantine file; the queue starts empty this session.")
            } catch {
                // Even a FRESH store cannot be opened (disk full, sandbox) —
                // the last resort stays the in-memory container: the app
                // works, the banner shows, the launch sweep is disabled.
                StorageFallback.inMemoryOnly = true
                NSLog("VidCompress: opening the SwiftData store failed (\(error)); a fresh store ALSO failed (\(error)) — falling back to an in-memory container. History is unavailable this session; the launch sweep is disabled.")
                container = try! ModelContainer(
                    for: JobRecord.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            }
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
