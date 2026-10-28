import SwiftUI
import SwiftData

@main
struct VidCompressApp: App {
    private let container: ModelContainer

    @StateObject private var coordinator: JobCoordinator

    init() {
        do {
            container = try ModelContainer(for: JobRecord.self)
        } catch {
            // Fall back to an in-memory store if the document store is corrupt.
            container = try! ModelContainer(
                for: JobRecord.self,
                configurations: [.init(isStoredInMemoryOnly: true)]
            )
        }
        _coordinator = StateObject(wrappedValue: JobCoordinator(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
        }
        .modelContainer(container)
    }
}
