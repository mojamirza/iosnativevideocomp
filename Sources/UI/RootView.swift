import SwiftUI
import PhotosUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

// Root screen: pillar banner + list of compression jobs,
// with the "compressing row" (progress + cancel + error + report).

struct RootView: View {
    @EnvironmentObject private var coordinator: JobCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var showingSetup = false
    @State private var importedVideos: [PickedVideo] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var importError: String?
    @State private var importStep: ImportStep?
    @State private var dropActive = false
    @State private var confirmingBatchDelete = false
    @State private var showPresetEditor = false
    @State private var showAboutSettings = false
    @State private var showPresetManager = false
    @State private var confirmingClearFinished = false
    /// OWNED split-view column visibility (regular widths): selection mode
    /// collapses to detail-only so the floating sidebar can never overlay
    /// the selection toolbar; exiting restores the automatic layout.
    @State private var regularColumns: NavigationSplitViewVisibility = .automatic
    /// DURABLE SETUP SESSION: owned HERE — outside the compact/regular body
    /// branches — so the shell swap across the size-class threshold (which
    /// tears the setup sheet's subtree down and re-presents it with
    /// showingSetup still true) cannot take the user's session with it:
    /// probes, the trim window, rotation, a picked poster and the preset
    /// choice all survive the re-presentation. Reset on every NEW import.
    @StateObject private var setupSession = SetupSession()

    // COMPACT DRAWER (tiny windowed/Split View widths): the MAIN PAGE is the
    // base layer and the sidebar slides OVER it — edge-swipe opens, swipe
    // left / backdrop tap / Done closes. NavigationSplitView's compact
    // presentations kept landing on the sidebar and offered no reliable way
    // back (programmatic columnVisibility is ignored while presented, and a
    // pre-set selection did not push the detail on iPadOS 26), so compact is
    // owned by this drawer; regular widths keep the side-by-side split view.
    @State private var sidebarOpen = false
    /// Live drag position 0…1 (nil while not dragging).
    @State private var dragProgress: CGFloat?
    /// Progress when the current drag began.
    @State private var dragAnchor: CGFloat?

    /// IN-FLIGHT IMPORT GATE: Photos (onChange), Files (fileImporter) and
    /// drag-and-drop each run independently — with a multi-GB copy in
    /// progress, none of them can know the work overlaps unless the UI
    /// PREVENTS starting a second one. Without this gate two concurrent
    /// loops both write importStep, the last finisher wins
    /// `importedVideos`, and the loser's copies are unreachable for
    /// deletion at setup dismissal (they wait for the once-per-process
    /// launch sweep). Toolbar import controls and both empty-state pickers
    /// disable while this is set; every import function guards on it too
    /// (state has no visibility into a sheet already on screen).
    @State private var isImporting = false
    /// The ONE guard all three entry points and the disabled controls read.
    private var importBusy: Bool { importStep != nil || isImporting }

    var body: some View {
        if hSizeClass == .compact {
            compactShell
        } else {
            regularShell
        }
    }

    // MARK: shells

    /// Regular/fullscreen widths: the classic side-by-side split view, with
    /// OWNED column visibility (selection mode drives it).
    private var regularShell: some View {
        NavigationSplitView(columnVisibility: $regularColumns) {
            sidebarList
        } detail: {
            interactiveList
        }
    }

    /// Compact widths: main page first, sidebar as an interactive drawer.
    private var compactShell: some View {
        GeometryReader { geo in
            let drawerWidth = min(320, geo.size.width * 0.82)
            let progress = drawerProgress
            ZStack(alignment: .leading) {
                // MAIN PAGE — the base layer: compact always lands here.
                // (A NavigationStack hosts it so the toolbar — import
                // buttons, the drawer opener — keeps rendering outside of
                // NavigationSplitView.)
                NavigationStack {
                    interactiveList
                        .navigationBarTitleDisplayMode(.inline)
                }
                .offset(x: progress * drawerWidth * 0.25)
                .simultaneousGesture(openEdgeGesture(width: drawerWidth))

                // Backdrop: dims with progress, tap closes.
                Color.black.opacity(0.35 * Double(progress))
                    .ignoresSafeArea()
                    .allowsHitTesting(progress > 0.02)
                    .onTapGesture { closeDrawer() }

                // SIDEBAR drawer panel.
                VStack(spacing: 0) {
                    drawerHeader
                    sidebarList
                }
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                .background(Color.appScreen.ignoresSafeArea())
                .offset(x: drawerWidth * (progress - 1))
                .shadow(color: .black.opacity(0.25 * Double(progress)), radius: 18, x: 4)
                .gesture(closeGesture(width: drawerWidth))
            }
        }
    }

    /// The drawer's own header (no system nav bar in a drawer): sidebar-style
    /// large title + the explicit way back to the main page.
    private var drawerHeader: some View {
        HStack {
            Text("VidCompress")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                closeDrawer()
            } label: {
                Label("Main page", systemImage: "chevron.backward")
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The shared sidebar rows — the regular split-view column AND the
    /// compact drawer panel both render this.
    private var sidebarList: some View {
        List {
            SidebarSavingsSection()

            Section("Presets") {
                Button {
                    showPresetManager = true
                } label: {
                    Label("Manage presets…", systemImage: "slider.horizontal.3")
                }
            }

            Section {
                Button {
                    showAboutSettings = true
                } label: {
                    Label("About & Settings", systemImage: "info.circle")
                }
            } footer: {
                Text(versionFooter)
            }
        }
        .navigationTitle("VidCompress")
        // The sidebar column must match the detail column (Color.appScreen):
        // the List's own grouped background is the gray that made the app
        // look different between fullscreen and Split View in dark mode.
        .scrollContentBackground(.hidden)
        .background(Color.appScreen)
    }

    // MARK: compact drawer gestures

    private var drawerProgress: CGFloat {
        if let dragProgress { return min(max(dragProgress, 0), 1) }
        return sidebarOpen ? 1 : 0
    }

    /// Leading-edge swipe (first 16pt, horizontal-dominant) opens the
    /// drawer — the main page's vertical scroll and the rows' swipe-to-
    /// delete are untouched (they start further in / dominate vertically).
    private func openEdgeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                guard v.startLocation.x < 16,
                      abs(v.translation.width) > abs(v.translation.height) else { return }
                if dragAnchor == nil { dragAnchor = sidebarOpen ? 1 : 0 }
                dragProgress = (dragAnchor ?? 0) + v.translation.width / width
            }
            .onEnded { v in
                snapDrawer(finalProgress: dragProgress ?? (sidebarOpen ? 1 : 0),
                           velocity: v.velocity.width)
            }
    }

    /// Horizontal swipe on the drawer panel closes it (flick-aware).
    private func closeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                if dragAnchor == nil { dragAnchor = sidebarOpen ? 1 : 0 }
                dragProgress = (dragAnchor ?? 1) + v.translation.width / width
            }
            .onEnded { v in
                snapDrawer(finalProgress: dragProgress ?? (sidebarOpen ? 1 : 0),
                           velocity: v.velocity.width)
            }
    }

    private func snapDrawer(finalProgress: CGFloat, velocity: CGFloat) {
        let open = finalProgress > 0.5 || velocity > 320
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            sidebarOpen = open
        }
        dragAnchor = nil
        dragProgress = nil
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            sidebarOpen = false
        }
    }

    private var versionFooter: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        // VERSION ONLY: the build number and the "outputs and history live
        // in the queue" pointer read as a status line from Settings, not a
        // footer — the sidebar already SHOWS what it lives on.
        return "VidCompress \(v)"
    }

    /// The root list with its INTERACTION layer: drop handling, toolbar and
    /// import entry points. Second slice of the former body chain — the full
    /// chain exceeded the type-checker's complexity budget (CI).
    private var interactiveList: some View {
        presentedList
            .onDrop(of: [UTType.movie],
                    isTargeted: $dropActive,
                    perform: handleDrop)
            .overlay { dropTargetOverlay }
            .navigationTitle(
                // SELECTION MODE shows the count like Photos does. Empty or
                // not, the detail pane says QUEUE: "VidCompress" already
                // lives in the menu bar and the sidebar title — the large
                // title is the pane's NAME, and the pane IS the queue.
                coordinator.selectionMode && !coordinator.selectedIDs.isEmpty
                    ? "\(coordinator.selectedIDs.count) selected"
                    : "Queue")
            // LARGE title on the split-view detail (the Files/Notes pattern);
            // the compact shell overrides this with .inline below.
            .navigationBarTitleDisplayMode(.large)
            .toolbar { importToolbar }
            // Batch actions (selection mode): Save/Delete hug the TRAILING
            // edge (a leading Spacer keeps them clear of any overlay that
            // slides in from the leading edge — iPadOS 26's floating sidebar
            // covered a leading "Select all" on device). "Select all" itself
            // lives in the TOP bar while selecting (the native Mail
            // pattern), never behind anything. Hidden while the compact
            // drawer is open (it floats in the system-toolbar layer).
            // EACH action gates on what its tap WILL actually do: Save
            // counts selected rows that really have an output to write
            // (a failed/cancelled-only selection used to sit enabled and
            // do nothing). Delete is the ONE stop-everything action: it
            // cancels selected active jobs on the way out (deleteSelected
            // → delete → per-row flags), so a separate Cancel button was
            // the same gesture with an extra confirmation — removed per
            // device report. Save + Delete only.
            .toolbar {
                if coordinator.selectionMode && !mainChromeHiddenByDrawer {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        Button {
                            Task { await coordinator.saveSelectedToPhotos() }
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .disabled(coordinator.saveableSelectedCount == 0)
                        Button(role: .destructive) {
                            confirmingBatchDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(coordinator.selectedIDs.isEmpty)
                    }
                }
            }
            // Photos library selection (multi-select → batch)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importFromLibrary(items) }
            }
            // Files app selection (UIDocumentPickerViewController-backed,
            // multi-select → batch)
            .fileImporter(isPresented: $showFiles,
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await importFromFiles(urls) }
                }
            }
    }

    /// Alerts, the setup sheet and the lifecycle tasks. Third slice of the
    /// former body chain.
    private var presentedList: some View {
        queueList
            .alert("Import failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importError ?? "")
            }
            // One-time notice: the system refused background continuation for
            // this install (re-signed bundle IDs are the usual cause). The
            // queue still works — in the foreground only.
            .alert("Background compression unavailable",
                   isPresented: Binding(
                       get: { coordinator.backgroundSubmissionDenied },
                       set: { if !$0 { coordinator.backgroundSubmissionDenied = false } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The system refused background processing for this install — this can happen after the app was re-signed. Compression still works normally; just keep the app open in the foreground until the queue finishes.")
            }
            // Batch save result notice (selection mode).
            .alert("Batch save", isPresented: Binding(
                get: { coordinator.batchNotice != nil },
                set: { if !$0 { coordinator.batchNotice = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(coordinator.batchNotice ?? "")
            }
            // Setup skipped enqueueing infeasible target-size rows (an
            // encode that could only end in a verification failure is not
            // run). The user DESERVES the count: silence would read as
            // "the app did less than promised".
            .alert("Videos skipped", isPresented: Binding(
                get: { coordinator.skippedNotice != nil },
                set: { if !$0 { coordinator.skippedNotice = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(coordinator.skippedNotice ?? "")
            }
            // Shortcuts handoff: an unreadable video is removed WITH a
            // notice — silence read as "the action did nothing".
            .alert("Couldn't add video", isPresented: Binding(
                get: { coordinator.importNotice != nil },
                set: { if !$0 { coordinator.importNotice = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(coordinator.importNotice ?? "")
            }
            // Purged unfinished rows (source copies the system removed): a
            // one-time notice instead of rows silently vanishing.
            .alert("Some unfinished items were removed", isPresented: Binding(
                get: { coordinator.purgedRowsNotice != nil },
                set: { if !$0 { coordinator.purgedRowsNotice = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(coordinator.purgedRowsNotice ?? "")
            }
            // Fat-finger protection for the batch delete. ALERT (not a
            // confirmationDialog): dialogs anchor to a source view — from
            // the whole list that anchor reads as detached on iPad; alerts
            // center themselves and need no anchor.
            .alert("Delete \(coordinator.selectedIDs.count) selected items?",
                   isPresented: $confirmingBatchDelete) {
                Button("Delete", role: .destructive) { coordinator.deleteSelected() }
                Button("Keep", role: .cancel) { }
            } message: {
                Text("The selected videos and their history entries will be removed. This cannot be undone.")
            }
            // SINGLE-ROW DELETE confirmation — presented HERE (list level),
            // not in the row: destructive prompts from inside rows silently
            // failed on iPadOS 26 and the delete appeared to skip
            // confirmation. Swipe, buttons and ⋯ menus all arm pendingDeleteID.
            .alert("Delete this item?",
                   isPresented: Binding(
                       get: { coordinator.pendingDeleteID != nil },
                       set: { if !$0 { coordinator.pendingDeleteID = nil } })) {
                Button("Delete", role: .destructive) { coordinator.confirmPendingDelete() }
                Button("Keep", role: .cancel) { }
            } message: {
                Text("The compressed video and its history entry will be removed. This cannot be undone.")
            }
            // SINGLE-ROW CANCEL/STOP confirmation — same root-level alert.
            .alert(coordinator.jobs.first(where: { $0.id == coordinator.pendingCancelID })?.state == .queued
                       ? "Remove from queue?" : "Stop this compression?",
                   isPresented: Binding(
                       get: { coordinator.pendingCancelID != nil },
                       set: { if !$0 { coordinator.pendingCancelID = nil } })) {
                Button(coordinator.jobs.first(where: { $0.id == coordinator.pendingCancelID })?.state == .queued
                       ? "Remove from queue" : "Stop & discard",
                       role: .destructive) { coordinator.confirmPendingCancel() }
                Button("Keep going", role: .cancel) { }
            } message: {
                Text(coordinator.jobs.first(where: { $0.id == coordinator.pendingCancelID })?.state == .queued
                     ? "The queued job will be removed from the list."
                     : "Encoding progress will be lost and the partial file deleted.")
            }
            // Fat-finger protection for Clear Finished (menu bar).
            .alert("Delete all finished rows?",
                   isPresented: $confirmingClearFinished) {
                Button("Delete \(coordinator.jobs.filter { [.done, .failed, .cancelled].contains($0.state) }.count) finished items", role: .destructive) {
                    coordinator.clearFinished()
                }
                Button("Keep", role: .cancel) { }
            } message: {
                Text("Outputs and history entries of finished jobs will be removed. This cannot be undone.")
            }
            .sheet(isPresented: $showingSetup, onDismiss: {
                setupSheetDismiss()
            }) {
                SetupFlowView(videos: importedVideos,
                              onDone: { showingSetup = false },
                              session: setupSession)
                    .presentationDetents([.large])
            }
            // MENU BAR sheets (File → New Preset, Help → About & Settings).
            .sheet(isPresented: $showPresetEditor) {
                PresetEditorView { newPreset in
                    var customs = PresetStore.loadCustom()
                    if let idx = customs.firstIndex(where: { $0.id == newPreset.id }) {
                        customs[idx] = newPreset
                    } else {
                        customs.append(newPreset)
                    }
                    PresetStore.saveCustom(customs)
                    PresetStore.setLastUsedPreset(newPreset.id)
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $showAboutSettings) {
                AboutSettingsSheet()
                    .presentationDetents([.medium, .large])
            }
            // SIDEBAR → preset manager: browse/create/edit/duplicate/delete
            // presets, plus the metadata policy (moved out of the compress
            // bottom bar, which had grown too dense).
            .sheet(isPresented: $showPresetManager) {
                PresetManagerSheet()
                    .presentationDetents([.medium, .large])
            }
            .task {
                coordinator.attach(context: modelContext)
                if #available(iOS 26.0, *) {
                    BackgroundCompress.attach(coordinator: coordinator)
                }
                VideoInbox.hostCoordinator = coordinator
                coordinator.loadHistory()
                // Shortcuts handoff: videos added by "Compress video" while
                // the app was away get enqueued now (history first, so the
                // queue spins up against a fully loaded store).
                if #available(iOS 17.0, *) {
                    await VideoInbox.consume(with: coordinator)
                }
            }
            // Shortcuts handoff does not wait for the next launch: a video
            // stashed while the app is merely BACKGROUNDED must be picked up
            // the moment the scene becomes active again (the launch .task
            // above only ever fires once per process).
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // Lift a background-revocation pause (queued jobs continue).
                coordinator.resumeIfBackgroundPaused()
                if #available(iOS 17.0, *) {
                    Task { await VideoInbox.consume(with: coordinator) }
                }
            }
            // Keep the screen awake while any job is active — an auto-lock
            // mid-encode suspends the app and kills the hardware encoder.
            .onChange(of: coordinator.hasActiveJob) { _, active in
                UIApplication.shared.isIdleTimerDisabled = active
            }
            // MENU BAR requests: the commands flip one-shot flags; RootView
            // consumes them and owns the sheets/dialogs they trigger.
            .onChange(of: coordinator.requestFilesImport) { _, requested in
                if requested {
                    coordinator.requestFilesImport = false
                    showFiles = true
                }
            }
            .onChange(of: coordinator.requestPresetEditor) { _, requested in
                if requested {
                    coordinator.requestPresetEditor = false
                    showPresetEditor = true
                }
            }
            .onChange(of: coordinator.requestSettings) { _, requested in
                if requested {
                    coordinator.requestSettings = false
                    showAboutSettings = true
                }
            }
            .onChange(of: coordinator.requestClearFinished) { _, requested in
                if requested {
                    coordinator.requestClearFinished = false
                    confirmingClearFinished = true
                }
            }
            // Haptic polish, ONE source of truth: the coordinator's ticks
            // fire on terminal transitions regardless of which row a job
            // currently lives in (a finished row MOVES between ForEachs, so
            // per-row feedback was rebuilt around its own event and never
            // fired). Cancellations don't tick — the user did that.
            .sensoryFeedback(.success, trigger: coordinator.completionTick)
            .sensoryFeedback(.error, trigger: coordinator.failureTick)
    }

    /// The queue screen — SEPARATED CARDS hosted in a LIST (v1.8.5): the
    /// cards look exactly like the v1.6.3 presentation (own rounded surface
    /// on the AMOLED canvas, icon+count section headers, spacing between),
    /// but the CONTAINER is the platform's — UIKit-grade scrolling and
    /// NATIVE swipe actions. A DragGesture bolted onto scroll content kept
    /// fighting the scroll recognizer on iPadOS 26 (device reports: cards
    /// could not be scrolled, only the background; exclusive vs simultaneous
    /// made no difference). All destructive intents still arm the root-level
    /// confirmations; when the queue is empty the list has no rows and the
    /// empty state rides above it as an overlay (ContentUnavailableView
    /// and bordered buttons are not List-row safe — v1.7.1 lesson kept).
    private var queueList: some View {
        List {
            if !coordinator.jobs.isEmpty {
                if let step = importStep {
                    ImportStatusCard(step: step)
                        .padding(.horizontal)
                        .cardListRow()
                }

                if StorageFallback.inMemoryOnly {
                    storageFallbackBanner
                        .padding(.horizontal)
                        .cardListRow()
                }

                let active = coordinator.activeJobs
                let finished = coordinator.finishedJobs

                if !active.isEmpty {
                    sectionHeader("In progress", icon: "hourglass", count: active.count)
                        .cardListRow()
                    QueueStatusBar()
                        .padding(.horizontal)
                        .cardListRow()
                    ForEach(Array(active.enumerated()), id: \.element.id) { rowIndex, job in
                        // ALL row chrome (paddings, list-row insets, swipe
                        // actions) lives INSIDE JobRowView behind the
                        // render-skip — re-evaluating it per coordinator
                        // publish reconfigured the finished cells during
                        // encodes and ticked their ⋯ menus on iPadOS 26.
                        JobRowView(job: job, coordinator: coordinator,
                                   selectionActive: coordinator.selectionMode,
                                   isSelected: coordinator.selectedIDs.contains(job.id),
                                   rowIndex: rowIndex)
                            .equatable()
                    }
                }

                if !finished.isEmpty {
                    sectionHeader("History", icon: "clock", count: finished.count)
                        .cardListRow()
                    ForEach(Array(finished.enumerated()), id: \.element.id) { rowIndex, job in
                        // Row chrome inside the render-skip (see the active
                        // rows above) — trailing Delete, leading Retry for
                        // failed/cancelled.
                        JobRowView(job: job, coordinator: coordinator,
                                   selectionActive: coordinator.selectionMode,
                                   isSelected: coordinator.selectedIDs.contains(job.id),
                                   rowIndex: rowIndex)
                            .equatable()
                    }
                }

                StorageFooter()
                    .padding(.top, 6)
                    .cardListRow()
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        // TRUE black in dark mode on every screen-level container (see
        // Color.appScreen) — fullscreen, Split View and Stage Manager all
        // show the same AMOLED-black canvas; light mode is unchanged.
        .scrollContentBackground(.hidden)
        .background(Color.appScreen)
        // EMPTY STATE overlay (NOT a row: ContentUnavailableView's layout
        // collapses and its bordered action buttons don't tap reliably
        // inside rows on iPadOS 26 — the v1.7.1 lesson, kept).
        .overlay {
            if coordinator.jobs.isEmpty {
                VStack(spacing: 16) {
                    if let step = importStep {
                        ImportStatusCard(step: step)
                            .padding(.horizontal)
                    }
                    if StorageFallback.inMemoryOnly {
                        storageFallbackBanner
                            .padding(.horizontal)
                    }
                    EmptyState(photoItems: $photoItems,
                               onFiles: { showFiles = true },
                               disabled: importBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appScreen)
            }
        }
    }

    /// Card-era section header: tinted icon + headline + count capsule.
    private func sectionHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.bold())
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Spacer()
            Text("\(count)")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
        }
        .padding(.horizontal)
        .padding(.top, 14)
        // BOTTOM BREATHING ROOM: with no bottom padding the headline sat
        // flush against the status card / first job card below it — device
        // report: the section read as one stacked blob. The card rows carry
        // their own .vertical(7), so this is the only seam that needed it.
        .padding(.bottom, 8)
    }

    /// COMPACT: while the drawer is open, the main page's toolbar chrome is
    /// hidden. iPadOS 26 hosts toolbars in a floating system layer ABOVE
    /// the drawer's ZStack — the selection-mode bottom bar (Select all /
    /// Save / Delete) and the import buttons would otherwise stay visible
    /// and clash with the drawer (device report: the select-all button
    /// “fell behind the side menu”). They return when the drawer closes.
    private var mainChromeHiddenByDrawer: Bool {
        hSizeClass == .compact && sidebarOpen
    }

    // MARK: body parts — extracted from `body` so the total expression stays
    // inside the type-checker's complexity budget (CI hit "unable to
    // type-check this expression in reasonable time" once drag & drop landed
    // inline; the same rule the row card already documents).

    private var importToolbar: some ToolbarContent {
        // Single Group + explicit return: the two-group builder form
        // defeated ToolbarContentBuilder inference (CI type-check error).
        return Group {
            if !mainChromeHiddenByDrawer {
            ToolbarItemGroup(placement: .topBarLeading) {
                // COMPACT DRAWER: the main page owns an explicit opener in
                // addition to the leading-edge swipe.
                if hSizeClass == .compact {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                            sidebarOpen = true
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                    }
                    .accessibilityLabel("Open sidebar")
                }
                // SELECTION mode entry (native list-app pattern): batch save
                // and batch delete for finished rows. On regular widths the
                // split view CLOSES ITS SIDEBAR while selecting — the
                // floating sidebar slid over the selection bottom bar's
                // leading area on device (the "Select all fell behind" bug
                // is structurally impossible then: trailing-anchored items
                // only, sidebar closed). Exiting selects restores it.
                if !coordinator.jobs.isEmpty {
                    Button(coordinator.selectionMode ? "Cancel" : "Select") {
                        if coordinator.selectionMode {
                            // Animate the mode so the circles spring in /
                            // out instead of popping (device report).
                            withAnimation(.spring(response: 0.25,
                                                  dampingFraction: 0.85)) {
                                coordinator.exitSelectionMode()
                            }
                            if hSizeClass != .compact {
                                withAnimation {
                                    regularColumns = .automatic
                                }
                            }
                        } else {
                            withAnimation(.spring(response: 0.25,
                                                  dampingFraction: 0.85)) {
                                coordinator.enterSelectionMode()
                            }
                            if hSizeClass != .compact {
                                withAnimation {
                                    regularColumns = .detailOnly
                                }
                            }
                        }
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if coordinator.selectionMode {
                    // SELECT ALL lives in the TOP bar during selection (the
                    // native Mail pattern) — the leading slot of a bottom
                    // bar is exactly where iPadOS 26's floating sidebar
                    // overlays landed on it (device report).
                    Button("Select all") {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            coordinator.selectAll()
                        }
                    }
                } else {
                    // DIRECT toolbar buttons: a PhotosPicker nested inside a
                    // Menu is unreliable on device (the sheet can be swallowed
                    // by the menu's dismissal). The empty-state pickers — which
                    // work on device — are direct, so the toolbar matches that
                    // proven shape.
                    // preferredItemEncoding: .current — without it the picker
                    // may hand back a TRANSCODED HDR→SDR movie; the engine
                    // must see the original pixels to keep the color tags.
                    PhotosPicker(selection: $photoItems, matching: .videos,
                                 preferredItemEncoding: .current) {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .accessibilityLabel("Import from Photos")
                    .disabled(importBusy)

                    Button {
                        showFiles = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel("Import from Files")
                    .disabled(importBusy)
                }
            }
            }
        }
    }

    @ViewBuilder
    private var dropTargetOverlay: some View {
        if dropActive {
            RoundedRectangle(cornerRadius: 24)
                .fill(.tint.opacity(0.14))
                .overlay {
                    Label("Drop videos to import", systemImage: "arrow.down.doc")
                        .font(.headline)
                }
                .padding(10)
                .allowsHitTesting(false)
        }
    }

    /// Drop entry point: movies dropped from Files or Photos enter the same
    /// setup flow as picked videos.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Drop gate (see importBusy): a second drop during an active
        // import is refused, never queued alongside it. The flag is HELD
        // across the detached copy work — @State reads/writes run on the
        // MainActor here — and cleared when the Task body finishes, so no
        // importer can be presented over this one's in-flight loop.
        guard !showingSetup, !isImporting, !providers.isEmpty else { return false }
        isImporting = true
        Task {
            defer { isImporting = false }
            var picked: [PickedVideo] = []
            var i = 0
            for provider in providers {
                importStep = ImportStep(
                    total: providers.count, done: i,
                    current: provider.suggestedName ?? "dropped video")
                guard let url = await ImportHelpers.urlFromDrop(provider) else { continue }
                if let copy = await ImportHelpers.copyOffMain(url) {
                    let thumb = await Thumbnails.make(url: copy)
                    picked.append(PickedVideo(url: copy, thumbnail: thumb))
                }
                i += 1
            }
            importStep = nil
            if picked.isEmpty {
                importError = "The dropped videos could not be imported."
            } else {
                importedVideos = picked
                // NEW import → fresh session (see the comment at the other
                // import paths): the drop path matches pick/library, so a
                // cancelled run of the same files also doesn't resurrect
                // a stale session.
                setupSession.reset(for: picked)
                showingSetup = true
            }
        }
        return true
    }

    private func importFromLibrary(_ items: [PhotosPickerItem]) async {
        // OVERLAP GATE: Photos, Files and drag-drop are independent entry
        // points — without this, picking from Files while a multi-GB
        // Photos copy is loading lets both loops race importStep and
        // importedVideos, leaking the loser's copies (setup dismissal can
        // only delete what the WINNER put in importedVideos). The gate is
        // also why the import controls disable while it is held.
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var picked: [PickedVideo] = []
        var i = 0
        for item in items {
            importStep = ImportStep(
                total: items.count, done: i,
                // Human-readable: the raw itemIdentifier (a UUID) said
                // nothing. The FILES get date-stamped names too (see
                // ImportedVideo) — this is the per-file progress line.
                current: "Video \(i + 1) of \(items.count)")
            do {
                let url = try await ImportHelpers.copyFromLibrary(item)
                let thumb = await Thumbnails.make(url: url)
                picked.append(PickedVideo(url: url, thumbnail: thumb))
            } catch {
                // Unreadable/untransferable item — skipped; the
                // batch card shows what made it through.
            }
            i += 1
        }
        photoItems = []
        importStep = nil
        if picked.isEmpty {
            importError = "The selected videos could not be imported."
        } else {
            importedVideos = picked
            // NEW import → fresh session: a cancelled run of the SAME
            // files must not resurrect its trim/rotation/poster (a
            // 5-second trim the user had abandoned would silently
            // reappear). Shell-swap REPLAY keeps its session precisely
            // because this runs only on the import paths — not on
            // re-presentation.
            setupSession.reset(for: picked)
            showingSetup = true
        }
    }

    private func importFromFiles(_ urls: [URL]) async {
        // OVERLAP GATE (see importFromLibrary): the Files picker must not
        // start a second copy loop over an in-flight import.
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var picked: [PickedVideo] = []
        var i = 0
        for url in urls {
            // IMPORT PROGRESS: per-file card while the batch copies — a
            // multi-GB import silently froze the UI before this existed.
            importStep = ImportStep(
                total: urls.count, done: i, current: url.lastPathComponent)
            // The multi-GB copy runs OFF the main actor —
            // inline on MainActor it froze the UI for the
            // entire copy duration.
            if let copy = await ImportHelpers.copyOffMain(url) {
                let thumb = await Thumbnails.make(url: copy)
                picked.append(PickedVideo(url: copy, thumbnail: thumb))
            }
            i += 1
        }
        importStep = nil
        if picked.isEmpty {
            importError = "The selected files could not be copied into the app's storage."
        } else {
            importedVideos = picked
            // NEW import → fresh session: a cancelled run of the SAME
            // files must not resurrect its trim/rotation/poster (a
            // 5-second trim the user had abandoned would silently
            // reappear). Shell-swap REPLAY keeps its session precisely
            // because this runs only on the import paths — not on
            // re-presentation.
            setupSession.reset(for: picked)
            showingSetup = true
        }
    }

    /// The setup sheet closed — Cancel, Compress, or a swipe down. Import
    /// copies that never became a job (cancelled setup, batch videos skipped
    /// after a failed probe) would otherwise leak in Caches/Imports until
    /// the NEXT launch's sweep — multi-GB on large batches. Delete the
    /// leftovers now; enqueued jobs keep their copies (the queue needs them).
    /// GUARD: a shell swap mid-setup (dragging the Split View divider across
    /// the compact threshold) tears the two body branches — and the sheet
    /// with them — down and rebuilds the other one. That fires onDismiss
    /// WHILE showingSetup is still true, and deleting here would destroy
    /// the copies of a setup that is about to re-present empty. The copies
    /// then wait for the next real dismissal (or the launch sweep).
    private func setupSheetDismiss() {
        guard !showingSetup else { return }
        let jobPaths = Set(coordinator.jobs.map {
            $0.sourceURL.standardizedFileURL.path
        })
        let leftovers = importedVideos.map(\.url).filter {
            !jobPaths.contains($0.standardizedFileURL.path)
        }
        JobCoordinator.deleteImportCopies(leftovers)
        importedVideos = []
    }

    /// One-time banner (stable per-process flag set in App.init): the
    /// SwiftData store failed to open and history runs memory-only.
    private var storageFallbackBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("History may not survive this session — the app couldn't open its database and is running without it. Your videos are not affected.")
                .font(.footnote)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
    }
}

// MARK: - Shared queue summary (ONE source of truth)

extension JobCoordinator {
    /// Jobs that are queued or in flight, in EXECUTION ORDER (oldest
    /// first): the queue workers pick the OLDEST queued row (the array is
    /// newest-first for history — enqueue inserts at 0 — and the worker
    /// takes `lastIndex`), so the natural reading of "In progress" is
    /// currently-working FIRST, then next up, then the rest of the line.
    /// The plain REVERSE of the filtered array IS that order, structurally
    /// better than re-sorting by createdAt: history stays newest-first at
    /// every write (enqueue, relaunch fetch), so reversing reproduces the
    /// enqueue order EXACTLY — even for rows enqueued back-to-back where
    /// equal Date() granularity would make a timestamp sort's stability
    /// ambiguous. Display-only: progress/headline are order-insensitive.
    var activeJobs: [Job] {
        Array(jobs
            .filter { [.queued, .analyzing, .compressing, .verifying].contains($0.state) }
            .reversed())
    }

    /// Terminal jobs (done / failed / cancelled).
    var finishedJobs: [Job] {
        jobs.filter { [.done, .failed, .cancelled].contains($0.state) }
    }

    /// Queue-level progress 0…1 over the ACTIVE queue (equal share per job;
    /// verifying counts its full point, encoding/analyzing its live fraction,
    /// queued nothing). The old duplicate computations — one in the in-list
    /// status bar, one in the sidebar — were a drift hazard.
    var queueProgress: Double {
        let active = activeJobs
        guard !active.isEmpty else { return 0 }
        var sum = 0.0
        for job in active {
            switch job.state {
            case .verifying: sum += 1
            case .compressing, .analyzing:
                sum += min(max(job.progress, 0), 1)
            default: break
            }
        }
        return min(max(sum / Double(active.count), 0), 1)
    }

    /// One-line "what's happening" readout for the queue.
    var queueHeadline: String {
        let active = activeJobs
        let encoding = active.first { $0.state == .compressing }
        if let encoding, !encoding.sourceName.isEmpty {
            let queued = active.filter { $0.state == .queued }.count
            return queued > 0
                ? "Encoding \(encoding.sourceName) · \(queued) queued"
                : "Encoding \(encoding.sourceName)"
        }
        return "Preparing…"
    }

    /// BATCH REMAINING-TIME estimate over the whole ACTIVE queue, in
    /// seconds — the status bar's "about N min left" clause. Built only
    /// from honest signals:
    /// • the RUNNING job extrapolates its remaining time from REAL
    ///   elapsed vs progress (the same math the row's ETA line shows),
    ///   falling back to its remaining plan duration at 1× realtime
    ///   while progress is too small to extrapolate from;
    /// • every QUEUED job's plan duration is scaled by the running
    ///   job's OBSERVED realtime multiplier — a clip encoding at 6×
    ///   finishes in a sixth of its runtime, so quoting raw durations
    ///   would inflate the total by the same factor. The estimate
    ///   self-corrects every second as the observed speed refines.
    /// nil when nothing is measurable (idle, or only analyzing) — the
    /// caption then simply omits the clause. Analyzing/verifying passes
    /// are seconds-scale and add nothing.
    var queueRemainingEstimate: TimeInterval? {
        guard let running = activeJobs.first(where: { $0.state == .compressing }),
              let started = running.startedAt,
              let plan = running.plan
        else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let p = min(max(running.progress, 0), 1)
        // Demonstrated encode speed as a realtime multiplier (1× = the
        // encode takes as long as the video runs). Only meaningful once
        // some progress and a little elapsed time exist.
        let speed: Double? = (p > 0.02 && elapsed > 0.5)
            ? (p * plan.duration) / elapsed
            : nil
        // Running job: extrapolate from real elapsed vs progress; before
        // that is possible, assume the remaining clip runs at 1×.
        var total = p > 0.02 ? elapsed / p * (1 - p) : (1 - p) * plan.duration
        for job in activeJobs where job.state == .queued {
            guard let d = job.plan?.duration, d > 0 else { continue }
            // Scale by the machine's demonstrated throughput when known.
            total += d / max(speed ?? 1, 0.2)
        }
        return max(total, 0)
    }

    /// The formatted "about … left" clause for the status bar, or nil
    /// when there is nothing worth showing — no estimate, or under the
    /// 5 s floor the row-level ETA also uses (avoids "about 0 s left").
    /// Same phrasing family as the row ETA ("about 4 min 30 s left").
    var queueRemainingLabel: String? {
        guard let t = queueRemainingEstimate, t >= 5 else { return nil }
        let s = Int(t.rounded())
        if s < 60 { return "about \(s) s left" }
        let m = s / 60
        if m < 60 {
            let sec = s % 60
            return sec > 0 ? "about \(m) min \(sec) s left" : "about \(m) min left"
        }
        let h = m / 60
        let rem = m % 60
        return rem > 0 ? "about \(h) h \(rem) min left" : "about \(h) h left"
    }
}

/// LIFETIME STATS — the running tally of what the app has actually saved,
/// computed from the persisted history (every done record stores its in/out
/// bytes). Read by the sidebar savings card; negative deltas (outputs that
/// grew) never inflate the total.
enum LifetimeStats {
    static func summarize(_ records: [JobRecord]) -> (videos: Int, saved: Int64) {
        var vids = 0
        var saved: Int64 = 0
        for r in records {
            let delta = r.inBytes - r.outBytes
            if delta > 0 { saved += delta; vids += 1 }
            else if r.outBytes > 0 { vids += 1 }
        }
        return (vids, saved)
    }
}

// MARK: - Queue status bar + import progress

/// One import step for the progress card (file-scope: it lives in
/// RootView's @State).
struct ImportStep: Equatable {
    let total: Int
    let done: Int
    let current: String
}

/// IMPORT PROGRESS: a batch copy of multi-GB files used to be a frozen
/// screen with no signal. Now one card counts through the batch.
private struct ImportStatusCard: View {
    let step: ImportStep

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Importing \(min(step.done + 1, step.total)) of \(step.total)")
                    .font(.subheadline.weight(.semibold))
                Text(step.current)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
    }
}

/// QUEUE-LEVEL status bar: one progress bar over the whole ACTIVE queue
/// (equal share per job) and a "what's happening / how much is left"
/// readout — a passive live status card. (It carried a user Pause control
/// until v1.7.4; the feature was removed — it never behaved dependably on
/// device, and per-row Cancel / the Queue menu cover stopping work.)
private struct QueueStatusBar: View {
    @EnvironmentObject private var coordinator: JobCoordinator

    // Status math lives ONCE on the coordinator (queueHeadline / queueProgress
    // / activeJobs) — the sidebar card and this bar can never disagree.
    /// Remaining jobs = working + waiting (the full active queue). "N jobs
    /// left" is the honest count for BOTH: a queued row is work not yet
    /// done; calling the pair "in flight" would claim two workers are running.
    private var active: [JobCoordinator.Job] { coordinator.activeJobs }
    private var fraction: Double { coordinator.queueProgress }
    private var headline: String { coordinator.queueHeadline }

    /// Caption line: "Queue 42% · 3 jobs left · about 12 min left". The
    /// remaining-time clause only appears while an estimate exists (a job
    /// is actually encoding — see queueRemainingEstimate). monospacedDigit
    /// keeps the ticking seconds from jittering the line width.
    private var caption: String {
        var parts = ["Queue \(Int((fraction * 100).rounded()))%",
                     "\(active.count) job\(active.count == 1 ? "" : "s") left"]
        if let remaining = coordinator.queueRemainingLabel {
            parts.append(remaining)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.needle")
                    .font(.callout)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    // Ticks EVERY SECOND (TimelineView, same pattern as the
                    // row ETA): progress callbacks alone could leave the
                    // remaining-time clause frozen between them.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(caption)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            ProgressView(value: fraction)
        }
        .padding(14)
        .background(Color.appCard,
                    in: RoundedRectangle(cornerRadius: AppTheme.largeCardRadius))
    }
}

// MARK: - Sidebar cards

/// LIFETIME SAVINGS in the sidebar: the app's headline number, visible no
/// matter how far the queue list is scrolled (and the ONLY place it lives
/// now — the main page no longer repeats it). Deleting rows removes their
/// savings too, so the number reflects what is in the app right now. The
/// whole section collapses when history is empty.
private struct SidebarSavingsSection: View {
    @Query(filter: #Predicate<JobRecord> { $0.stateRaw == "done" })
    private var records: [JobRecord]

    var body: some View {
        let s = LifetimeStats.summarize(records)
        if s.videos > 0, s.saved > 0 {
            Section("Lifetime") {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You've saved \(ByteCountFormatter.string(fromByteCount: s.saved, countStyle: .file))")
                            .font(.callout.weight(.semibold))
                        Text("Across \(s.videos) finished compression\(s.videos == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Storage footer

/// Small transparency line: how much storage the app keeps, and the policy.
/// Cleanup itself is automatic (sources deleted after success, orphan sweep
/// at launch) — this just shows the current footprint.
private struct StorageFooter: View {
    @EnvironmentObject private var coordinator: JobCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var usageText: String?
    @State private var appeared = false

    /// Recompute trigger: any row added/removed or state change — exactly
    /// the events that move the footprint (output promoted into Documents,
    /// import copy deleted, row deleted). Progress ticks are deliberately
    /// EXCLUDED so an encoding batch doesn't re-walk the directories twice
    /// a second. (The old version computed once per view lifetime and the
    /// number went stale the moment the first job finished.)
    private var footprintKey: String {
        let states = coordinator.jobs.map { $0.state.rawValue }.joined(separator: ",")
        return "\(coordinator.jobs.count)|\(states)"
    }

    var body: some View {
        Group {
            if let usageText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(usageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal)
            }
        }
        .task(id: footprintKey) {
            await refresh()
        }
        // External changes (Files-app deletions, the orphan sweep after a
        // background return) never touch the jobs array — re-measure when
        // the user comes back to the app. The appeared flag skips the
        // initial fire: the footprint task already covers first appearance.
        .task(id: scenePhase) {
            if appeared, scenePhase == .active { await refresh() }
            appeared = true
        }
    }

    private func refresh() async {
        // Directory sizing is disk I/O — keep it off the main actor. The
        // cancelled check discards a stale measurement when a newer trigger
        // already replaced this task.
        let text = await Task.detached { Self.describe() }.value
        if !Task.isCancelled { usageText = text }
    }

    static func describe() -> String? {
        let outputs = dirSize(JobCoordinator.outputsDirectory())
        let imports = dirSize(JobCoordinator.importsDirectory())
        guard outputs + imports > 0 else { return nil }
        let fmt: (Int64) -> String = {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        return "App storage: \(fmt(outputs + imports)) · \(fmt(outputs)) compressed videos kept for sharing — source copies are cleaned up automatically"
    }

    /// RECURSIVE: the footprint must count subdirectories too — a plain
    /// contentsOfDirectory sees a folder only as a tiny stub entry, so any
    /// nested content under Outputs/Imports was silently dropped from the
    /// reported total.
    static func dirSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in enumerator {
            let values = try? f.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}

/// About & Settings sheet: the menu bar's About/Settings destination.
/// The privacy toggles bind to the same UserDefaults keys PrivacyScrub
/// reads, so they stay in sync with the preset manager's copies.
private struct AboutSettingsSheet: View {
    // Same key PrivacyScrub reads (the literal string drifted once).
    @AppStorage(PrivacyScrub.keepDateKey) private var keepCreationDate = true
    @AppStorage(PrivacyScrub.stripAllKey) private var stripAllMetadata = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Privacy") {
                    // Strip-all makes the date toggle inert (it overrides it)
                    // — say so AND disable it instead of letting a toggle
                    // silently do nothing.
                    Toggle("Keep creation date", isOn: $keepCreationDate)
                        .disabled(stripAllMetadata)
                        .listRowBackground(Color.appCard)
                    Toggle("Strip all metadata", isOn: $stripAllMetadata)
                        .listRowBackground(Color.appCard)
                    Text(stripAllMetadata
                         ? "Strip-all is on: every metadata item is removed — the keep-creation-date toggle is inert until you turn Strip-all off."
                         : "Outputs never carry location data. Strip-all removes the creation date too — a fully anonymous file with no metadata track.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.appCard)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .listRowBackground(Color.appCard)
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                        .listRowBackground(Color.appCard)
                    LabeledContent("Engine", value: "VideoToolbox · H.264 / HEVC")
                        .listRowBackground(Color.appCard)
                }
                Section("Project") {
                    Link("VidCompress on GitHub", destination: URL(string: "https://github.com/mojamirza/iosnativevideocomp")!)
                        .listRowBackground(Color.appCard)
                }
            }
            // Same screen-level token as every other screen (Color.appScreen).
            .scrollContentBackground(.hidden)
            .background(Color.appScreen)
            .navigationTitle("About & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    @Binding var photoItems: [PhotosPickerItem]
    let onFiles: () -> Void
    /// Import controls go INACTIVE while an import is in flight (the
    /// overlap gate) — starting a second copy loop races importStep and
    /// leaked the loser's copies.
    var disabled: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.badge.ellipsis")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No compressions yet")
                .font(.title3.weight(.semibold))
            Text("Pick one video — or a whole batch — from your library or the Files app to start.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            // The two big entry points SIDE BY SIDE (explicit request) —
            // real actions, not just directions.
            HStack(spacing: 12) {
                // .current encoding: deliver the ORIGINAL pixels — the
                // default may transcode an HDR clip to SDR before the
                // color-safe engine ever sees it.
                PhotosPicker(selection: $photoItems, matching: .videos,
                             preferredItemEncoding: .current) {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: 110)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onFiles) {
                    Label("Files", systemImage: "folder")
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: 110)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
            .disabled(disabled)

            Text("Or drag & drop videos here from Files or Photos while in Split View.")
                .font(.footnote)
                // .tertiary vanished on the black canvas — .secondary is the
                // lowest contrast that is still actually readable.
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Import helpers

enum ImportHelpers {
    enum ImportError: LocalizedError {
        case notImportable
        var errorDescription: String? {
            "The selected video could not be imported. Try sharing it to the Files app and picking it from there."
        }
    }

    /// PhotosPicker → local copy inside the app's Imports folder. Throws on
    /// total failure so the UI can surface the problem instead of silently
    /// doing nothing.
    static func copyFromLibrary(_ item: PhotosPickerItem) async throws -> URL {
        // Preferred: native URL transferable (iCloud-aware, memory-safe — the
        // system exports the movie to a temp file). Often unavailable for
        // library assets, so failure here just falls through.
        if let url = try? await item.loadTransferable(type: URL.self) {
            // The physical copy runs OFF the main actor — a multi-GB copy
            // inline on MainActor freezes the UI for its whole duration.
            if let copy = await copyOffMain(url) { return copy }
            return url
        }
        // Fallback: FileRepresentation streaming — the system hands us a temp
        // file that we copy to disk. Never holds the whole video in RAM
        // (loading `Data` would OOM-crash on large library files).
        if let video = try? await item.loadTransferable(type: ImportedVideo.self) {
            return video.url
        }
        // The old in-memory `Data` fallback is GONE: a library video that
        // still hit it loaded the WHOLE multi-GB movie into RAM and
        // OOM-crashed the app. An exotic provider that can't hand us a file
        // now gets an honest error alert instead of a crash.
        throw ImportError.notImportable
    }

    /// Security-scoped access + directory transfer, entirely OFF the main
    /// actor: multi-GB copies otherwise stall the UI for their duration.
    static func copyOffMain(_ url: URL) async -> URL? {
        await Task.detached {
            SecurityScoped(url: url).importCopy()
        }.value
    }

    /// Pulls a file URL out of a dropped item provider. Files-app drops hand
    /// over security-scoped URLs; some sources deliver raw Data instead —
    /// written to a temp file first (AVFoundation sniffs the container, the
    /// extension is cosmetic). nil when the provider has nothing usable.
    static func urlFromDrop(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadItem(forTypeIdentifier: UTType.movie.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("drop-\(UUID().uuidString).mov")
                    do {
                        try data.write(to: tmp)
                        cont.resume(returning: tmp)
                    } catch {
                        cont.resume(returning: nil)
                    }
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Coordinated read + copy for files that may be iCloud Drive documents:
    /// a placeholder must be DOWNLOADED before it can be copied, and touching
    /// iCloud documents without an NSFileCoordinator races the sync daemon
    /// (the documented requirement). With .forUploading the coordinator hands
    /// the block a fully materialized file (the same path for plain local
    /// files). Returns false when the copy could not be made.
    static func coordinatedCopy(from url: URL, to dest: URL) -> Bool {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var ok = false
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [.forUploading], error: &coordError) { readURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: dest)
                ok = true
            } catch {
                ok = false
            }
        }
        if let coordError {
            NSLog("VidCompress: coordinated read failed: \(coordError.localizedDescription)")
        }
        return ok
    }
}

/// Memory-safe Transferable for library videos: imports via a file
/// representation instead of an in-memory `Data` blob.
private struct ImportedVideo: Transferable {
    let url: URL

    /// Import-name stamp: “Video yyyy-MM-dd HH.mm.ss” (POSIX-locale, so the
    /// shape is stable on every device/region).
    static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "'Video 'yyyy-MM-dd HH.mm.ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url, allowAccessingOriginalFile: true)
        } importing: { received in
            let dir = JobCoordinator.importsDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = received.file.pathExtension
            let ext2 = ext.isEmpty ? "mov" : ext
            // HUMAN-READABLE import names: the video's own RECORDING date,
            // not the import moment — "Video 2026-11-10 10.56.43" used to
            // match the status-bar clock because `Date()` stamped the
            // import. The true date lives in two places, tried in order:
            // the movie's QuickTime metadata (the camera writes it there)
            // and then the temp file's filesystem creation date (some
            // handoff providers preserve it). Both misses fall back to
            // now. The metadata read is the synchronous commonMetadata
            // (cheap: container-header bytes) — the async load(.…)
            // pipeline can't help here because the NAME is needed inside
            // this synchronous closure, BEFORE analyze() ever runs.
            let asset = AVURLAsset(url: received.file)
            let created: Date = {
                if let meta = AVMetadataItem.metadataItems(
                    from: asset.commonMetadata,
                    filteredByIdentifier: .commonIdentifierCreationDate).first,
                   let d = meta.dateValue {
                    return d
                }
                if let fs = try? FileManager.default.attributesOfItem(
                    atPath: received.file.path)[.creationDate] as? Date {
                    return fs
                }
                return Date()
            }()
            // POSIX locale pins the format on every device/region; the '.'
            // separator keeps it filename-safe.
            let base = Self.nameFormatter.string(from: created)
            var dest = dir.appendingPathComponent("\(base).\(ext2)")
            // COLLISION SUFFIX "(n)": the native Files/Rename shape (same
            // format renameOutput appends). The old "-1" looked like a
            // typo in the middle of a readable name.
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(base) (\(n)).\(ext2)")
                n += 1
            }
            // FileRepresentation always delivers a real file on disk — copy it
            // directly (NO removeItem first: dest never exists on a fresh
            // import and removing would throw, killing the whole transfer).
            try FileManager.default.copyItem(at: received.file, to: dest)
            return ImportedVideo(url: dest)
        }
    }
}

/// Security-scoped access wrapper for fileImporter (document picker) URLs.
struct SecurityScoped {
    let url: URL
    init(url: URL) { self.url = url }

    func importCopy() -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        // Keep the original filename so history rows and exports are
        // recognizable; add -1, -2, … suffixes on collisions.
        let base = url.deletingPathExtension().lastPathComponent
        let dir = JobCoordinator.importsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            // "(n)" matches the native duplicate shape (and renameOutput) —
            // "-1" read like a typo inside the name.
            dest = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        // Coordinated copy: iCloud Drive placeholders get downloaded by the
        // file coordinator first; plain local files copy straight through.
        guard ImportHelpers.coordinatedCopy(from: url, to: dest) else { return nil }
        return dest
    }
}

enum Thumbnails {
    static func make(url: URL, maxDimension: CGFloat = 320, at time: Double? = nil) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 1
        let at = CMTime(seconds: time ?? (dur > 2 ? dur * 0.15 : 0.1), preferredTimescale: 600)
        guard let (img, _) = try? await gen.image(at: at) else { return nil }
        return UIImage(cgImage: img)
    }
}

/// List-row chrome for card content: full-bleed, no separator, no row
/// surface — the card paints its own; the appScreen shows between cards.
/// Internal (not private): JobRowView applies it too — its row chrome
/// sits behind the render-skip (see JobRows.swift).
extension View {
    func cardListRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
