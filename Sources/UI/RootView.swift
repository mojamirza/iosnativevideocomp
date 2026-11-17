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
    /// S8: Reduce Motion — the drawer then animates FADE-ONLY (no spatial
    /// slide, no card reflow); direct-manipulation drags still follow the
    /// finger, but open/close settles fade in place.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// the selection toolbar; exiting restores the SNAPSHOT the user had
    /// (S2 — one @State cannot serve app-forced and user-chosen values,
    /// so entry captures, exit restores exactly).
    @State private var regularColumns: NavigationSplitViewVisibility = .automatic
    /// S2: the user's own column visibility, captured at selection entry
    /// and restored verbatim at exit — a manual collapse before Select
    /// survives the mode instead of being force-reopened.
    @State private var preSelectionColumns: NavigationSplitViewVisibility = .automatic
    /// DURABLE SETUP SESSION: owned HERE — outside the compact/regular body
    /// branches — so the shell swap across the size-class threshold (which
    /// tears the setup sheet's subtree down and re-presents it with
    /// showingSetup still true) cannot take the user's session with it:
    /// probes, the trim window, rotation, a picked poster and the preset
    /// choice all survive the re-presentation. Reset on every NEW import.
    @StateObject private var setupSession = SetupSession()

    // COMPACT DRAWER (tiny windowed/Split View widths): the MAIN PAGE is the
    // base layer and NARROWS as the sidebar opens — the panel ends up
    // BESIDE the queue (cards reflow to the leftover width, like a real
    // split view) instead of covering it; where the canvas is too small
    // for both, the panel overlaps the page's leading strip like a
    // slide-over. Edge-swipe opens, swipe left / backdrop tap / Done
    // closes. NavigationSplitView's compact presentations kept landing on
    // the sidebar and offered no reliable way back (programmatic
    // columnVisibility is ignored while presented, and a pre-set selection
    // did not push the detail on iPadOS 26), so compact is owned by this
    // drawer; regular widths keep the side-by-side split view.
    @State private var sidebarOpen = false
    /// Live drag position (rubber-banded slightly past 0…1 during a drag,
    /// S12; nil while not dragging).
    @State private var dragProgress: CGFloat?
    /// Progress when the current drag began.
    @State private var dragAnchor: CGFloat?
    /// S6/S11: the compact canvas width, observed so chrome-hiding and the
    /// VoiceOver modality can be scoped to the regime where the drawer
    /// panel REALLY covers the page (narrow panes) instead of every open.
    @State private var compactCanvasWidth: CGFloat = 0
    /// S12: one tick per GESTURE-driven snap — drives the snap haptic.
    @State private var snapTick = 0

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
        Group {
            if hSizeClass == .compact {
                compactShell
            } else {
                regularShell
            }
        }
        // S1: NavigationSplitView installs its OWN sidebar toggle in the
        // detail's leading toolbar on iPadOS 26 — tapping it writes through
        // the binding and slides the floating sidebar back over the
        // selection bottom bar (and over the leading Cancel). Fighting the
        // user by forcing .detailOnly back would pin them in a mode they
        // just tried to leave; the HONEST response is to auto-exit
        // selection the moment the premise "sidebar closed while
        // selecting" no longer holds.
        .onChange(of: regularColumns) { _, newValue in
            guard coordinator.selectionMode,
                  newValue != .detailOnly,
                  hSizeClass != .compact else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                coordinator.exitSelectionMode()
            }
        }
        // S3/S9: drawer state (sidebarOpen, dragProgress, dragAnchor) is a
        // COMPACT-shell concept and regularColumns must not carry a stale
        // .detailOnly across the threshold — exit-selection in compact used
        // to skip the restore and regular remounted sidebar-less.
        .onChange(of: hSizeClass) { _, _ in shellSwapReset() }
        // S12: snap haptic — fires only on gesture-driven snaps (snapTick).
        .sensoryFeedback(.impact(weight: .light), trigger: snapTick)
    }

    // MARK: shells

    /// Regular/fullscreen widths: the classic side-by-side split view, with
    /// OWNED column visibility (selection mode drives it). S4: on iOS 26 the
    /// sidebar column is a floating glass panel — an opaque appScreen canvas
    /// inside it painted a hard black slab over the system material (and
    /// rendered differently between fullscreen and Split View), so the
    /// column gets the same clear-canvas treatment as the drawer; iOS 17–25
    /// keeps the pinned opaque canvas (the V3 gray-canvas lesson).
    private var regularShell: some View {
        NavigationSplitView(columnVisibility: $regularColumns) {
            sidebarList(clearCanvas: drawerUsesGlass)
        } detail: {
            interactiveList
        }
    }

    /// Compact widths: main page first, sidebar as an interactive drawer
    /// that shares the canvas.
    private var compactShell: some View {
        GeometryReader { geo in
            let canvas = geo.size.width
            let drawerWidth = min(320, canvas * 0.82)
            let progress = drawerProgress
            // S8: Reduce Motion — no spatial slide and no card reflow; the
            // panel fades in place over the full-width page (opacity-only).
            let slideFree = reduceMotion
            // SIDE-BY-SIDE OPEN (user request: "when you open the side menu
            // the card's size should change so the side menu fits alongside
            // the main page"): the main page's width is the canvas minus
            // the revealed drawer, floored at 45% — cards reflow to the
            // reduced width live (no animation code here: the open/close
            // spring flows through drawerProgress, and the interactive
            // drag feeds it per-frame by design).
            let mainWidth = slideFree
                ? canvas
                : max(canvas - drawerWidth * progress,
                      canvas * 0.45)
            // S6: the OVERLAP STRIP — how much of the revealed drawer really
            // sits ON the page. In the pure side-by-side phase the page's
            // leading edge coincides with the drawer's trailing edge, so
            // this is ZERO and there is no backdrop at all: both columns
            // fully interactive and undimmed, like the system's own split
            // view. Only where the 45% floor binds (narrow Split View panes
            // and windowed mode) does the panel overlap the page's leading
            // strip, and only THAT strip dims and intercepts taps.
            let overlap = max(0, drawerWidth * progress - (canvas - mainWidth))
            // S6/S12: the page is VoiceOver-modal only while the panel
            // really covers it — otherwise VO could traverse the dimmed
            // page behind the panel.
            let covered = overlap > 24
            ZStack(alignment: .leading) {
                // MAIN PAGE — the base layer: compact always lands here.
                // (A NavigationStack hosts it so the toolbar — import
                // buttons, the drawer opener — keeps rendering outside of
                // NavigationSplitView.) Pinned to the TRAILING edge so its
                // right side always stays flush with the canvas: at full
                // width the pin is a no-op, while open the page's left
                // edge sits exactly beside the drawer — or, once the 45%
                // floor binds (a 320pt drawer can't fit beside 45% of a
                // 500pt pane), the panel overlaps the page's leading strip
                // like a slide-over instead of squeezing cards into
                // unreadable widths.
                NavigationStack {
                    interactiveList
                        .navigationBarTitleDisplayMode(.inline)
                }
                .frame(width: mainWidth)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .simultaneousGesture(openEdgeGesture(width: drawerWidth))
                .accessibilityHidden(covered)

                // Backdrop — SCOPED TO THE OVERLAP STRIP (S6): the old
                // full-canvas layer dimmed and hit-blocked the ENTIRE page
                // whenever the drawer was open, which turned side-by-side
                // into slide-over behavior. The strip exists only while
                // there is actual overlap, dims it, closes on tap. VO: an
                // offset never removes a view from the accessibility tree
                // (U2 device report) — hidden whenever not settled open.
                // N1: the ZStack slot is LEADING-aligned, but the covered
                // region starts at the PAGE's leading edge (canvas −
                // mainWidth) — with the 45% floor binding (narrow Split
                // View panes, windowed mode) that offset is real and the
                // unshifted strip sat entirely under the panel: dim
                // invisible, tap-to-close dead, S12 drops unreachable.
                // Shifted by exactly that offset, the strip's trailing
                // edge lands on the drawer's trailing edge
                // (canvas − mainWidth + overlap = drawerWidth·progress);
                // in the pure side-by-side and Reduce Motion regimes the
                // offset is zero, so those behaviors are unchanged.
                if overlap > 0.5 {
                    Color.black.opacity(0.35)
                        .frame(width: overlap)
                        .frame(maxHeight: .infinity)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { closeDrawer() }
                        // S12: a drop on the covered strip used to fail
                        // silently (the backdrop ate it) — the strip
                        // accepts the same movie drop as the page.
                        .onDrop(of: [UTType.movie],
                                isTargeted: $dropActive,
                                perform: handleDrop)
                        .accessibilityHidden(!sidebarOpen)
                        // N1: the shift goes OVER the whole interactive
                        // stack (outermost transform) — hit-testing is
                        // inverted through it, so the tap and the drop
                        // register exactly where the dim renders.
                        .offset(x: canvas - mainWidth)
                }

                // SIDEBAR drawer panel — FLOATING CHROME: Liquid Glass on
                // iOS 26+ (the panel floats over the dimmed content, glass
                // samples exactly what is behind it); the pinned screen
                // color below. The glass rectangle ignores the safe area so
                // the material runs edge-to-edge like the old fill, and the
                // shape is explicit — glassEffect's default is a capsule.
                VStack(spacing: 0) {
                    drawerHeader
                    sidebarList(clearCanvas: drawerUsesGlass)
                }
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                .background {
                    if #available(iOS 26.0, *) {
                        Rectangle().fill(Color.clear)
                            .glassEffect(.regular, in: Rectangle())
                            .ignoresSafeArea()
                    } else {
                        Rectangle().fill(Color.appScreen).ignoresSafeArea()
                    }
                }
                // DISTINCT EDGE (user report: the drawer's boundary melted
                // into the main page) — S13: only on the OPAQUE pre-26
                // panel. iOS 26 glass renders its own edge/highlight; the
                // hairline stacked on top of it read as a doubled, dirty
                // edge on device.
                .overlay(alignment: .trailing) {
                    if !drawerUsesGlass {
                        Rectangle()
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: 1)
                            .opacity(Double(progress))
                    }
                }
                // S8: fade-only under Reduce Motion — the panel never
                // translates (offset pinned at 0); opacity follows the drag
                // or the settle animation. A fully transparent closed panel
                // must not eat taps on the page's leading strip.
                .offset(x: slideFree ? 0 : drawerWidth * (progress - 1))
                .opacity(slideFree ? Double(progress) : 1)
                .allowsHitTesting(!slideFree || progress > 0.02)
                // Deeper shadow than the glass round (eb70e76): the drop
                // must separate the panel from the content UNDER it, not
                // just decorate it. This is now the ONE custom edge cue on
                // glass (the hairline above is glass-only-suppressed).
                .shadow(color: .black.opacity(0.4 * Double(progress)), radius: 24, x: 6)
                .gesture(closeGesture(width: drawerWidth))
                // VO: same U2 rule — while closed the panel's rows
                // ("Manage presets…", "About & Settings"), header button
                // and all were focusable while visually absent.
                .accessibilityHidden(!sidebarOpen)
            }
            // S6/S11: observe the canvas so mainChromeHiddenByDrawer can be
            // scoped to real overlap (initial: true seeds the first layout).
            .onChange(of: geo.size.width, initial: true) { _, width in
                compactCanvasWidth = width
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
    /// compact drawer panel both render this. S4: BOTH get `clearCanvas:
    /// true` on iOS 26 — the split-view column is a floating glass panel
    /// there (an opaque canvas painted a hard black slab over the system
    /// material) and the drawer's Liquid Glass panel must show through the
    /// list. iOS 17–25 keeps the pinned opaque screen color everywhere
    /// (the gray-canvas lesson: the List's own grouped background made the
    /// app look different between fullscreen and Split View in dark mode).
    private func sidebarList(clearCanvas: Bool = false) -> some View {
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
        .scrollContentBackground(.hidden)
        .background(clearCanvas ? Color.clear : Color.appScreen)
    }

    // MARK: compact drawer gestures

    /// Whether the drawer panel renders Liquid Glass (iOS 26+) — drives the
    /// sidebar list's canvas (an opaque canvas would sit ON the glass) and
    /// documents the fallback once instead of scattering availability
    /// checks. iOS 17–25 keeps the pinned opaque screen color.
    private var drawerUsesGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// S5/S8: ONE drawer animation — the tuned spring normally; under
    /// Reduce Motion a short non-spring fade (the drawer's slideFree layout
    /// makes that opacity-only).
    private var drawerAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2)
                     : .spring(response: 0.4, dampingFraction: 0.85)
    }

    /// S12: the live drag progress — already rubber-banded by the gestures,
    /// so no hard re-clamp here (the old min/max ate the overshoot).
    private var drawerProgress: CGFloat {
        if let dragProgress { return dragProgress }
        return sidebarOpen ? 1 : 0
    }

    /// S12: soft rubber-band resistance past the ends — the fraction keeps
    /// moving past 0/1 under the finger but with growing resistance (damped
    /// asymptote at ±55% of a drawer-width overshoot) instead of the old
    /// hard clamp.
    private func banded(_ fraction: CGFloat) -> CGFloat {
        guard fraction < 0 || fraction > 1 else { return fraction }
        let over = fraction < 0 ? fraction : fraction - 1
        let soft = over / (1 + abs(over)) * 0.55
        return fraction < 0 ? soft : 1 + soft
    }

    /// Leading-edge swipe (first 16pt, horizontal-dominant) opens the
    /// drawer — the main page's vertical scroll and the rows' swipe-to-
    /// delete are untouched (they start further in / dominate vertically).
    /// ACTIVATION IS LATCHED in onChanged: dragProgress is only ever set
    /// after the edge + horizontal-dominance guard passes AND the drag has
    /// real travel (S10: a micro-swipe in the edge strip — the row-swipe
    /// race — no longer visibly moves the drawer on its first pixels; full
    /// disambiguation from the rows' own leading swipe actions needs
    /// device evidence). onEnded can tell a real drawer drag from any
    /// other gesture that merely passed minimumDistance — a fast vertical
    /// scroll fling starting inside the edge strip never latches and must
    /// never snap the drawer (device report: a slightly-diagonal fling's
    /// velocity.width > 320 opened the drawer mid-scroll through the old
    /// nil-fallback).
    private func openEdgeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                guard v.startLocation.x < 16,
                      abs(v.translation.width) > abs(v.translation.height) else { return }
                if dragAnchor == nil { dragAnchor = sidebarOpen ? 1 : 0 }
                let fraction = v.translation.width / width
                guard abs(fraction) > 0.04 else { return }
                dragProgress = banded((dragAnchor ?? 0) + fraction)
            }
            .onEnded { v in
                // Non-activated drags (never latched) are IGNORED — no
                // fallback value, no velocity read.
                guard dragProgress != nil else { return }
                snapDrawer(finalProgress: dragProgress ?? 0,
                           velocity: v.velocity.width)
            }
    }

    /// Horizontal swipe on the drawer panel closes it (flick-aware).
    /// Same latch as the opener: only a drag that dominated horizontally
    /// in onChanged may snap in onEnded.
    private func closeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                if dragAnchor == nil { dragAnchor = sidebarOpen ? 1 : 0 }
                let fraction = v.translation.width / width
                guard abs(fraction) > 0.04 else { return }
                dragProgress = banded((dragAnchor ?? 1) + fraction)
            }
            .onEnded { v in
                guard dragProgress != nil else { return }
                snapDrawer(finalProgress: dragProgress ?? 1,
                           velocity: v.velocity.width)
            }
    }

    private func snapDrawer(finalProgress: CGFloat, velocity: CGFloat) {
        // S7: flick physics in BOTH directions — the old rule
        // (progress > 0.5 || velocity > 320) could only ever OPEN on
        // velocity: a fast leftward flick that left the drawer at 0.55
        // stayed open against the gesture's obvious intent.
        let open: Bool
        if velocity > 320 {
            open = true
        } else if velocity < -320 {
            open = false
        } else {
            open = finalProgress > 0.5
        }
        // S12: velocity-aware settle — fast flicks land quickly, slow
        // drags keep the relaxed spring. Reduce Motion: the fade.
        let speed = abs(velocity)
        withAnimation(reduceMotion
            ? drawerAnimation
            : .spring(response: speed > 900 ? 0.28 : 0.4,
                      dampingFraction: 0.85)) {
            sidebarOpen = open
        }
        snapTick += 1
        dragAnchor = nil
        dragProgress = nil
    }

    private func closeDrawer() {
        withAnimation(drawerAnimation) {
            sidebarOpen = false
        }
    }

    /// S1/S2/S3: selection mode's column choreography, split out of the
    /// toolbar button so the rules live in one place.
    private func enterSelectionColumns() {
        guard hSizeClass != .compact else { return }
        // S2: snapshot the USER's visibility verbatim.
        preSelectionColumns = regularColumns
        withAnimation(drawerAnimation) {
            regularColumns = .detailOnly
        }
    }

    private func restoreColumnsAfterSelection() {
        // S3: deliberately NOT gated on the current size class — exiting
        // while compact must still restore, or a later crossing back to
        // regular remounts a stale .detailOnly with the sidebar gone.
        withAnimation(drawerAnimation) {
            regularColumns = preSelectionColumns
        }
    }

    /// S3/S9: the shell swap across the compact↔regular threshold. Drawer
    /// state belongs to the compact shell — drop it instantly (the shells
    /// rebuild anyway; no animation survives the swap). And a selection
    /// entered in compact that crosses INTO regular applies the same
    /// collapse-to-detail-only premise as selection entry.
    private func shellSwapReset() {
        dragAnchor = nil
        dragProgress = nil
        sidebarOpen = false
        if hSizeClass != .compact, coordinator.selectionMode,
           regularColumns != .detailOnly {
            preSelectionColumns = .automatic
            regularColumns = .detailOnly
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
                } else if StorageFallback.storeReset {
                    storeResetBanner
                        .padding(.horizontal)
                        .cardListRow()
                }

                let active = coordinator.activeJobs
                let finished = coordinator.finishedJobs
                // N9: the queued "#N" ordinal's explicit input (see
                // JobRowView.queuedCount) — computed at the render level,
                // where the @Published `jobs` tick guarantees freshness.
                let queuedCount = coordinator.jobs.filter { $0.state == .queued }.count

                if !active.isEmpty {
                    sectionHeader("In progress", icon: "hourglass", count: active.count)
                        .cardListRow()
                    QueueStatusBar()
                        .padding(.horizontal)
                        .cardListRow()
                    ForEach(Array(active.enumerated()), id: \.element.id) { rowIndex, job in
                        // Row chrome lives OUTSIDE the render-skip (the
                        // b0bcec0 attempt to freeze it inside JobRowView
                        // never reached the hosting List row on iPadOS 26 —
                        // cards got default insets and visible separators).
                        JobRowView(job: job, coordinator: coordinator,
                                   selectionActive: coordinator.selectionMode,
                                   isSelected: coordinator.selectedIDs.contains(job.id),
                                   rowIndex: rowIndex,
                                   queuedCount: queuedCount)
                            .equatable()
                            .padding(.horizontal)
                            .padding(.vertical, 7)
                            .cardListRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !coordinator.selectionMode {
                                    Button(role: .destructive) {
                                        coordinator.requestCancel(jobID: job.id)
                                    } label: {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                }
                            }
                    }
                }

                if !finished.isEmpty {
                    sectionHeader("History", icon: "clock", count: finished.count)
                        .cardListRow()
                    ForEach(Array(finished.enumerated()), id: \.element.id) { rowIndex, job in
                        // Row chrome outside the render-skip (see the active
                        // rows above) — trailing Delete, leading Retry for
                        // failed/cancelled.
                        JobRowView(job: job, coordinator: coordinator,
                                   selectionActive: coordinator.selectionMode,
                                   isSelected: coordinator.selectedIDs.contains(job.id),
                                   rowIndex: rowIndex,
                                   queuedCount: queuedCount)
                            .equatable()
                            .padding(.horizontal)
                            .padding(.vertical, 7)
                            .cardListRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !coordinator.selectionMode {
                                    Button(role: .destructive) {
                                        coordinator.requestDelete(jobID: job.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if !coordinator.selectionMode,
                                   [.failed, .cancelled].contains(job.state) {
                                    // retry() itself guards a surviving source.
                                    Button {
                                        coordinator.retry(jobID: job.id)
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                    }
                                    .tint(.accentColor)
                                }
                            }
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
                    // The import card sits at the TOP of the page in BOTH
                    // states — with history it is the first list row; empty,
                    // it must not sink to the middle together with the
                    // empty state (device report). EmptyState absorbs the
                    // remaining height, so only IT centers.
                    if let step = importStep {
                        ImportStatusCard(step: step)
                            .padding(.horizontal)
                    }
                    if StorageFallback.inMemoryOnly {
                        storageFallbackBanner
                            .padding(.horizontal)
                    } else if StorageFallback.storeReset {
                        storeResetBanner
                            .padding(.horizontal)
                    }
                    EmptyState(photoItems: $photoItems,
                               onFiles: { showFiles = true },
                               disabled: importBusy)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// COMPACT: the main page's toolbar chrome hides ONLY while the drawer
    /// really covers the page's leading strip (S6/S11). In the pure
    /// side-by-side phase the system toolbar floats above the PAGE —
    /// trailing of the drawer panel — and nothing clashes, so chrome keeps
    /// rendering (and the structural toolbar pop of the old
    /// every-open hiding happens far less often; a toolbar item insertion
    /// cannot be cross-faded on iPadOS 26, that residual pop is a platform
    /// limit). Narrow panes, where the 45% floor binds, get the original
    /// behavior (device report: the select-all button "fell behind the
    /// side menu").
    private var mainChromeHiddenByDrawer: Bool {
        guard hSizeClass == .compact, compactCanvasWidth > 0 else { return false }
        let drawerWidth = min(320, compactCanvasWidth * 0.82)
        // overlap = drawerWidth·p − (canvas − mainWidth); with the floor,
        // canvas − mainWidth caps at 0.55·canvas → this closed form.
        let overlap = max(0, drawerWidth * drawerProgress
                              - compactCanvasWidth * 0.55)
        return overlap > 24
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
                        withAnimation(drawerAnimation) {
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
                // only, sidebar closed). Exiting restores the SNAPSHOT.
                if !coordinator.jobs.isEmpty {
                    Button(coordinator.selectionMode ? "Cancel" : "Select") {
                        if coordinator.selectionMode {
                            // Animate the mode so the circles spring in /
                            // out instead of popping (device report).
                            withAnimation(.spring(response: 0.25,
                                                  dampingFraction: 0.85)) {
                                coordinator.exitSelectionMode()
                            }
                            restoreColumnsAfterSelection()
                        } else {
                            withAnimation(.spring(response: 0.25,
                                                  dampingFraction: 0.85)) {
                                coordinator.enterSelectionMode()
                            }
                            enterSelectionColumns()
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
            var failed = 0
            var i = 0
            for provider in providers {
                importStep = ImportStep(
                    total: providers.count, done: i,
                    current: provider.suggestedName ?? "dropped video")
                // N8: a skipped provider must not skip the PROGRESS counter
                // — the old `continue` paths left `i` behind, so the next
                // item's card showed a stale "done" count (and a failed
                // item was silently swallowed).
                var copy: URL?
                if let url = await ImportHelpers.urlFromDrop(provider) {
                    copy = await ImportHelpers.copyOffMain(url)
                }
                if let copy {
                    let thumb = await Thumbnails.make(url: copy)
                    picked.append(PickedVideo(url: copy, thumbnail: thumb))
                } else {
                    failed += 1
                }
                i += 1
            }
            importStep = nil
            if picked.isEmpty {
                importError = "The dropped videos could not be imported."
            } else if failed > 0 {
                importError = failed == 1
                    ? "1 of \(providers.count) dropped videos couldn't be imported."
                    : "\(failed) of \(providers.count) dropped videos couldn't be imported."
                importedVideos = picked
                // NEW import → fresh session (see the comment at the other
                // import paths): the drop path matches pick/library, so a
                // cancelled run of the same files also doesn't resurrect
                // a stale session.
                setupSession.reset(for: picked)
                showingSetup = true
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
        var failed = 0
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
                // N8: a failed item is COUNTED and reported — "3 of 5
                // imported" used to read as full success.
                failed += 1
            }
            i += 1
        }
        photoItems = []
        importStep = nil
        if picked.isEmpty {
            importError = "The selected videos could not be imported."
        } else {
            // N8: partial failures surface NEXT TO the success — "3 of 5"
            // no longer reads as full success.
            if failed > 0 {
                importError = failed == 1
                    ? "1 of \(items.count) videos couldn't be imported (often storage or an unreadable item)."
                    : "\(failed) of \(items.count) videos couldn't be imported (often storage or an unreadable item)."
            }
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
        var failed = 0
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
            } else {
                // N8: counted and reported, never silent.
                failed += 1
            }
            i += 1
        }
        importStep = nil
        if picked.isEmpty {
            importError = "The selected files could not be copied into the app's storage."
        } else {
            // N8: partial failures surface next to the success.
            if failed > 0 {
                importError = failed == 1
                    ? "1 of \(urls.count) files couldn't be copied into the app's storage (often storage)."
                    : "\(failed) of \(urls.count) files couldn't be copied into the app's storage (often storage)."
            }
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
    /// after a failed probe) would otherwise leak in Application Support/
    /// Imports until
    /// the NEXT launch's sweep - multi-GB on large batches. Delete the
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

    /// P1: the on-disk store was UNOPENABLE and was quarantined (kept as a
    /// backup file) with a fresh store created — this session's history
    /// persists, and the user must know the old history is not simply gone.
    private var storeResetBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.yellow)
            Text("The app's history database couldn't be opened, so it was reset — compression history starts empty. Your videos are not affected, and the old history was kept in a backup file inside the app's storage.")
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

    /// WHOLE-BATCH queue percent (device report: the old per-active average
    /// reset to 0% the moment a video finished and the next one started —
    /// the bar read as restarting every job). The batch is every job that
    /// entered the queue since it last drained (coordinator.batchIDs):
    /// • terminal batch jobs (done/failed) stay CREDITED as full,
    /// • running/verifying jobs contribute their partial progress,
    /// • the denominator is the whole batch (terminal + active) — so a
    ///   3-video batch climbs 0 → ~33 → ~66 → 100% and never resets.
    /// Old history is never counted (not a batch member); when the queue
    /// drains the batch ends and the next one starts from 0. The status
    /// bar and the sidebar read this ONE implementation (drift hazard).
    var queueProgress: Double {
        let active = activeJobs
        guard !active.isEmpty else { return 0 }
        var sum = 0.0
        var total = 0.0
        // Credited completions: terminal batch members (a FAILED job's
        // processing did end — it reached a verdict — so it counts toward
        // the batch total instead of silently deflating the percent).
        for id in batchIDs {
            guard let job = jobs.first(where: { $0.id == id }),
                  [.done, .failed].contains(job.state) else { continue }
            sum += 1
            total += 1
        }
        // Live partials: verifying is a pass seconds from done; queued
        // rows contribute 0 honestly.
        for job in active {
            total += 1
            switch job.state {
            case .verifying: sum += 1
            case .compressing, .analyzing:
                sum += min(max(job.progress, 0), 1)
            default: break
            }
        }
        guard total > 0 else { return 0 }
        return min(max(sum / total, 0), 1)
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
        // FLOATING CHROME → Liquid Glass on iOS 26+ (same rule as the queue
        // status bar); the pinned card color is the iOS 17–25 fallback — the
        // old tint wash was a third chrome style, now unified.
        .chromeSurface(in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
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
        // PINNED OPAQUE CARD, deliberately NOT Liquid Glass: the glass look
        // on this bar was tried (eb70e76) and reverted on user request —
        // the live percent/ETA bar reads better as a solid elevated card
        // over the AMOLED canvas, like previous versions. (The import card
        // and the drawer keep their iOS 26 glass.)
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
    /// App-icon switch failures bubble here from the picker section and
    /// surface as a LIST-LEVEL alert (alerts presented from inside list
    /// content don't anchor reliably on iPadOS 26).
    @State private var iconFailure: String?

    var body: some View {
        NavigationStack {
            Form {
                // APP ICON (user request: "nowhere in settings that can
                // user change the icon"): alternate-icons picker over the
                // LAYERED Icon Composer .icon sets — dark mode / tinted /
                // clear Home Screen appearances adapt each one
                // automatically on iPadOS 26; the picker picks the color.
                Section {
                    AppIconPickerSection(failureText: $iconFailure)
                        .listRowBackground(Color.appCard)
                } header: {
                    Text("App icon")
                } footer: {
                    Text("Tap an icon to switch — iPadOS confirms the change with its own alert. Every icon is layered with its own dark artwork: dark mode and tinted or clear Home Screens adapt it automatically, and you can pick a different color any time.")
                }
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
            // Failure alert for the icon picker — anchored at the stack
            // level so it always presents (device lesson, see above).
            .alert("Couldn't change the icon",
                   isPresented: Binding(
                       get: { iconFailure != nil },
                       set: { if !$0 { iconFailure = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(iconFailure ?? "An unknown error occurred.")
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
            // N2: the copy into Imports FAILED — do NOT return the raw
            // temp URL. loadHistory rebuilds every source path as
            // Imports/<sourceName> and purges records whose file is
            // missing, so a queued job created on a temp export silently
            // vanished at the next relaunch (and iOS purges tmp
            // aggressively anyway — persisting the temp path would
            // restore a dead row at best). Fall through to the
            // FileRepresentation path instead: a second, system-mediated
            // copy attempt whose result IS an Imports copy; if that
            // fails too, the honest notImportable throw skips the item
            // like any other unreadable provider.
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
            // N8: the received file's size for the free-space preflight.
            let srcSize = ((try? FileManager.default.attributesOfItem(
                atPath: received.file.path))?[.size] as? Int64) ?? 0
            var dest = dir.appendingPathComponent("\(base).\(ext2)")
            // COLLISION SUFFIX "(n)": the native Files/Rename shape (same
            // format renameOutput appends). The old "-1" looked like a
            // typo in the middle of a readable name.
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(base) (\(n)).\(ext2)")
                n += 1
            }
            // FileRepresentation always delivers a real file on disk.
            // N8: MOVE first, not copy — the provider's temp file is
            // disposable, so a same-volume move is free (the old
            // copyItem streamed every byte twice: system export + our
            // copy). Cross-volume or refused moves fall back to the
            // plain copy. FREE-SPACE check before either: a copy onto a
            // nearly-full disk dies partway, and a partial dest is
            // cleaned before rethrowing (nothing strands until the
            // sweep).
            do {
                if srcSize > 0,
                   let free = JobCoordinator.volumeFreeBytes(at: dir),
                   free < srcSize + 64_000_000 {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if ((try? FileManager.default.moveItem(
                        at: received.file, to: dest)) == nil) {
                    try FileManager.default.copyItem(at: received.file, to: dest)
                }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
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
        // N8: FREE-SPACE PREFLIGHT before a multi-GB copy — a copy onto a
        // nearly-full disk dies partway (leaving a partial dest, see
        // coordinatedCopy's cleanup) and the item used to fail with no
        // reason surfaced. The source's size is known here (scoped access
        // is already held); demand it plus a flat working margin.
        let srcSize = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        if srcSize > 0,
           let free = JobCoordinator.volumeFreeBytes(at: dir),
           free < srcSize + 64_000_000 {
            NSLog("VidCompress: import refused — need \(srcSize) bytes, \(free) free")
            return nil
        }
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
        // N8: a FAILED copy leaves a PARTIAL dest on disk — remove it, or
        // it strands until the next launch's sweep (multi-GB).
        guard ImportHelpers.coordinatedCopy(from: url, to: dest) else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
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
private extension View {
    func cardListRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
