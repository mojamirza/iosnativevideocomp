# VidCompress — Full Project Review

**Scope:** every file in `Sources/`, `Tests/`, `project.yml`, `.github/workflows/ipa.yml`, `README.md`.
**Verification status:** static review only — this machine is Windows (no Xcode), so nothing was compiled or run. All findings come from reading the code; line numbers reference current `HEAD` (`ad4a2bc`). Any fix should be validated by the existing CI (unit-tests job) before merging.

---

## 1. Overall assessment

This is a genuinely well-engineered codebase — noticeably above the typical "AVAssetWriter demo" tier:

- **Engine correctness discipline is rare**: color-tag canonicalization through one resolver, session-anchor math shared by probe/engine/verifier, cancel-safe pipes with queued resume, stall heartbeats instead of wall-clock timers, collision-proof output promotion, scratch-then-promote lifecycle, and a verifier that re-opens real files instead of trusting the writer.
- **Honesty in the UI** (three-state verdicts, "(capped)" bitrates, "grew by X%" instead of clamped 0%, measured re-encode passes) is exactly the right instinct for a tool that wants to be trusted like HandBrake.
- **CI** builds and unit-tests on every push, with both unsigned and signed IPA paths. Good.

The gaps are concentrated in three areas: **a handful of real behavioral bugs** (one storage leak, two persistence/race issues), **iPad-specific UI professionalism** (single-column phone layout, no multitasking, no drag & drop, no keyboard shortcuts), and **docs drift** (the README describes a feature set that no longer exists).

---

## 2. Bugs

### High

**B1 — Cancelling the setup sheet leaks the imported source copies (multi‑GB) until next launch.**
`RootView` copies every picked video into `Caches/Imports` *before* presenting `SetupFlowView` (`onChange(of: photoItems)` / `fileImporter`). The sheet's **Cancel** (`Sources/UI/SetupFlow.swift:127` → `onDone()`) enqueues nothing and deletes nothing. `cleanupOrphans()` is guarded by the once-per-process `swept` flag and already ran at launch, so the copies survive until the *next* launch's sweep (and only if older than 1 h).
Same family: in a batch, videos whose probe **failed** are skipped by `start()` (`SetupFlow.swift:588`, `guard let probe = probes[i] else { continue }`) — their copies leak identically.
*Fix:* have `SetupFlowView` report which URLs became jobs (or delete the rest in `start()`/cancel), e.g. hand the imported URLs back to `RootView` and remove any that weren't enqueued.

**B2 — "Last used preset" never persists the user's actual choice.**
`analyze()` writes `PresetStore.setLastUsedPreset` once (`SetupFlow.swift:658`) — with the value it just *restored from that same key* (a no-op). Tapping a different `PresetRow` (`SetupFlow.swift:510`) only sets `selectedPreset`; neither the row action nor `start()` writes the key. Net effect: selection memory works only for presets created/edited in the editor (`savePreset`, `SetupFlow.swift:609‑610`), never for plain selection.
*Fix:* call `PresetStore.setLastUsedPreset(...)` in `start()` (and/or in the row tap).

**B3 — Double-enqueue race on the Shortcuts inbox at launch.**
`RootView.swift:174` (`.task`) and `RootView.swift:191` (`onChange(of: scenePhase) == .active`) both call `VideoInbox.consume` (`Sources/App/CompressVideoIntent.swift:135`). On cold launch both fire within the same UI turns; each lists the marker directory *before* deleting the marker it processes, and `probe(url:)` is awaited in between. If both Tasks list before either deletes, the same stashed video is enqueued twice.
*Fix:* make `consume` non-reentrant (an in-flight flag on the coordinator, or a serial actor), or split it into a synchronous "claim markers" pass followed by async processing.

### Medium

**B4 — `UIRequiresFullScreen: true` blocks Split View / Stage Manager** (`project.yml:20`).
For an iPad "pro" tool this is a strategic own-goal: the user cannot keep Files open beside the app, and it forecloses drag-and-drop import (see UI‑1/UI‑2). iPad apps that support all orientations + resizing are the professional default.

**B5 — Missing `UIInterfaceOrientationPortraitUpsideDown`** (`project.yml:22‑24`).
An iPad held upside-down (camera on top, Smart Keyboard flipped, Stage Manager quadrant) won't rotate.

**B6 — Batch jobs encode in reverse pick order.**
`enqueue` inserts at index 0 (`Sources/Store/JobCoordinator.swift:71`) and the worker takes the first `.queued` job in array order (`JobCoordinator.swift:131`). Picking v1, v2, v3 yields array `[v3, v2, v1]` → v3 encodes first, v1 last. A queue-centric tool should encode in the order the user picked (or visibly reorder with drag, see UI‑12).
*Fix:* process by `createdAt` ascending, or append queued jobs after the active section.

**B7 — Player sheet dead-end when both files are gone.**
The play button appears on every terminal row. `OutputPlayerSheet.load()` (`Sources/UI/JobRows.swift:906`) falls back to the source; for a **done** job the source import is deleted by design, and if the user also removed the output in Files, `playerItem(for:)` (`JobRows.swift:946`) returns nil → black rectangle with no message (the "compressed file is gone" text requires `sourceExists`).
*Fix:* honest empty state, and/or hide the play overlay when neither file exists (the row already caches `outputExists`/`sourceExists`).

**B8 — Odd-dimension sources with "Keep original" attempt an odd-height encode.**
`ResolutionClass.outputSize` evens the *display* size, but on the keep path the engine writes the source's *stored* dimensions from the format description (`CompressionEngine.swift:278`), and `scaleNeeded` is false whenever the difference is ≤ 1 px (`QualitySizeOptimizer.swift:152`). A 1920×1081 source therefore goes to VideoToolbox with height 1081 — 4:2:0 encoders require even dimensions, so the job dies with a generic encode error instead of a clear explanation (or a 1-px crop).
*Fix:* when stored dims are odd, round to even and scale/crop accordingly, or fail with a specific message naming the odd dimension.

### Low / polish

- **B9** — `OutputPlayerSheet.measureAspect` uses the deprecated synchronous `asset.tracks(withMediaType:)` (`JobRows.swift:925`; deprecated since iOS 15, can block). Switch to `loadTracks`. It's the only remaining sync-tracks call in the app.
- **B10** — `StorageFooter.describe()` sizes directories synchronously on the MainActor (`RootView.swift:310`). The codebase's own discipline bans sync disk I/O on render paths; Documents can hold hundreds of outputs. Move it off-main.
- **B11** — `NSCameraUsageDescription: ""` (`project.yml`) — the app never uses the camera; an empty usage string is noise and can trip App Store validation. Delete it. `NSPhotoLibraryUsageDescription` is likewise unnecessary (PhotosPicker needs no permission; only the add-only key matters).
- **B12** — Mixed UK/US spelling in user-facing copy: "Analysing…" (JobRows `stateLabel`, SetupFlow) vs "color", "recognizable". Pick one variety — US, given the "color-safe engine" branding.
- **B13** — The preset editor's fps slider (10–60) silently rewrites legacy caps: a preset stored with `fpsCap = 120` (model range is 1–240) opens clamped to 60 and saves as 60. Widen the slider or annotate when the stored value was outside it.
- **B14** — CI keychain password falls back to a hardcoded default (`ipa.yml:156`, `${KEYCHAIN_PASSWORD:-build-ci-pass}`). Low risk (throwaway keychain), but fail-fast when the secret is missing is better.
- **B15** — **README is materially stale.** It describes `ComplexityAnalyzer.swift` (doesn't exist), the "Smallest / Balanced / Best" adaptive quality goals (removed), "8 built-ins" (there are 3), and the old `Documents/Compressed` layout (outputs now live at Documents root, imports in `Caches/Imports`). The README is the project's front door and currently advertises deleted features while underselling the ones that replaced them (guaranteed target size with measured re-encodes, PSNR/SSIM scoring, privacy scrub, HDR→SDR conversion, Shortcuts intent).

---

## 3. UI / UX improvements (the focus)

### 3.1 iPad layout & multitasking — the biggest gap

1. **Single-column phone layout on a 12.9" display.** `RootView` is a `NavigationStack` + `ScrollView`; rows carry only `.padding(.horizontal)`, so cards stretch edge-to-edge past 1000 pt. Constrain content width (~680–760 pt, centered) or go further:
2. **`NavigationSplitView`** — sidebar: *Queue*, *History*, *Presets*; detail: selected job (report + player + actions). This is the "HandBrake on iPad" information shape, and it makes the app feel native-pro rather than a stretched iPhone app.
3. **Drag & drop import** (`.onDrop` for `.movie`/`.mpeg4Movie`/`.quickTimeMovie`) from Files or Photos in Split View — *the* iPad-native import affordance for a media utility. Prerequisite: B4 (fullscreen requirement currently prevents Split View entirely).
4. **Keyboard shortcuts** for hardware keyboards: ⌘O import, ⌘N new preset, Space play selected row, ⌫ delete, ⌘, settings. Ubiquitous on Pro iPads and cheap to add via `.keyboardShortcut`.

### 3.2 Setup flow (HandBrake-parity features)

5. **Sample-encode preview** — HandBrake's killer feature: encode a 5–10 s snippet at the chosen settings and play it side-by-side with the source *before* committing the whole file. All machinery already exists (the engine takes a plan; the player has a source/output toggle at matched timestamps). This would be a genuine differentiator no other iOS compressor has.
6. **Tap-to-play the source** in the setup card (the player sheet exists; only the thumbnail is missing a tap target).
7. **Per-video control in batch** — currently unanalyzable videos are silently skipped (with a footnote). Let the user exclude/include individual videos, and show *why* one failed.
8. **Audio options** — there's no "Mute audio" (minimum 32 kbps) and no passthrough. A pro tool should offer "copy audio track" for already-AAC sources (re-encoding AAC→AAC is pure loss), with the current always-AAC behavior as the safe default.
9. **A third rate mode: Quality (bpp)** — Bitrate and Target size exist; a "Quality" mode driven by the same bpp bands the editor's hint already uses (0.045 / 0.20 bits-per-pixel-frame) would be the honest VideoToolbox equivalent of HandBrake's RF slider.
10. **Advanced disclosure** — GOP length (currently `fps×2`), H.264 profile (Main), B-frames are hardcoded. Expose under an "Advanced…" disclosure with safe defaults, or at least document them in the preset editor footer.

### 3.3 Queue management

11. **Pause/resume** — the practical version: "pause" finishes the current job and holds the queue (engine-level mid-frame pause isn't feasible with AVAssetWriter). Even that is valuable for battery/thermals.
12. **Reorder queued jobs** — drag handles on `.queued` rows (jobs already live in an array; combine with fixing B6).
13. **Queue position in queued rows** — "Queued · 3rd" (currently just "Queued").
14. **Optional concurrency** — one-at-a-time is a deliberate memory decision; on M-series iPads with ample RAM, an opt-in "2 concurrent encodes" would be reasonable.

### 3.4 History

15. **Search / filter / sort** — by name, date, savings; a toolbar search field once there are dozens of rows.
16. **Multi-select bulk actions** — select rows → Share several / Delete / "Clear finished".
17. **Export the report** — a ShareLink for the report text from `ReportSheet` (pros paste these into tickets; the report is already string-rich).

### 3.5 Report & player polish

18. **`lineLimit(4)` truncates multi-line details** (`JobRows.swift:726`) — the color-drift details are multi-line *by construction*. Make report rows expandable (tap to toggle) or drop the limit; truncated verification detail in a verification-centric app undermines the pillar.
19. **Severity legend** — one caption line in `ReportSheet` explaining ✓ / ⚠ / ✗ semantics ("pass / worth a look / broken promise").
20. **Compare mode in the player** — the source/output toggle at matched timestamps is great; add pause-and-step (frame step button) for frame-accurate checking of the quality claims.

### 3.6 System integration & delight

21. **Live Activity** (Lock Screen / Dynamic Island, iOS 16.1+) for the active encode — the code already reports progress to the iOS 26 BG task; a Live Activity covers everyone else and is the marquee "professional" visual.
22. **Local notification when the queue drains** (opt-in) for backgrounded sessions.
23. **Haptics** — light impact on preset selection; a success pattern with count when a *batch* completes (currently one generic tick per job).
24. **Icon variants** — dark/tinted app icon appearances (iOS 18) for polish; current single-size 1024 icon is valid.
25. **Empty state** should advertise drag & drop once UI-3 lands.

### 3.7 Accessibility & i18n

26. **VoiceOver**: mark job rows `accessibilityElement(children: .combine)` with a composed summary ("Compressing vacation.mp4, 45 percent, High quality preset, Cancel available"). Icon-only buttons already have labels — good.
27. **Reduce Motion**: the custom `SwipeToDeleteModifier` springs should respect it.
28. **Localization**: all copy is hardcoded English. Move to a String Catalog (`.xcstrings`, auto-extracted by Xcode) — HandBrake ships ~15 languages and this app's audience is international (the code already handles Persian/Arabic digits thoughtfully).
29. **Dynamic Type**: semantic fonts are used consistently (good). Verify the pinned bottom bar at accessibility XXL sizes — it stacks many context rows (error + HDR note + lecture suggestion + privacy toggle + estimate) and can consume the screen; consider collapsing into a disclosure at large sizes.

---

## 4. Engine & architecture improvements

30. **Software-encode option — the single biggest un-pulled quality lever.** AVAssetWriter uses the *hardware* VideoToolbox encoder by default; hardware HEVC is fast but measurably softer than software at equal bitrate. Expose `AVVideoEncoderSpecification` with `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false` as a per-preset "Max quality (slower)" toggle. For an app claiming HandBrake-grade output, this matters more than any UI skin.
31. **Two-pass / CRF parity note**: VideoToolbox exposes neither true 2-pass nor CRF; the measured re-encode correction (up to 2 extra passes) is a legitimate substitute — document it in the README so HandBrake comparisons are honest.
32. **Batch analysis is sequential** (`analyze()` probes one-by-one). A bounded task group (3–4 wide) would cut a 30-video setup from ~30×probe to ~8×probe.
33. **Output filename stamp** includes preset name/res/bitrate — consider adding the codec (`-hevc`/`-h264`) for users producing both variants of the same source.
34. **Test gaps** (all pure logic, CI-runnable): `SessionAnchor` (the documented edge cases: video 0 + audio 0.5 → 0; video 1 + audio nil → 1), `SampleDescription.depth` (byte-level hvcC offset-17 parse, avcC profile 110/122/244), `Preset` legacy decode (display-string codec/resolution spellings, clamping), `OptimizerPlan.estimatedBytes`, `renameOutput` sanitization (hostile chars, 150-byte CJK cap, dot-prefix), `presetStamp` non-Latin fallback.
35. **Verifier budget**: the 60 s verify cap with ≤30 s for quality extras is well-designed; on long 4K files the 4-frame PSNR sample can be tight. Scaling sample count to *remaining* budget (rather than fixed 4 with an 18 s cutoff) would make the score more stable on slow storage.

---

## 5. What's already good (keep and protect)

- **Color pipeline correctness**: one canonical resolver feeding both buffer attachments and writer settings, with real SDK constants — and verifier enforcement. This is the app's spine; guard it with the suggested tests.
- **Cancel/failure plumbing**: `EngineFlags` queued-resume design, stall heartbeats, `forceVerifyTerminal` backstop, late-wake guard, `reviveWorker` generation counter. Careful, hard-won concurrency code.
- **Storage lifecycle**: scratch-then-promote, collision-proof names, backup exclusion, orphan sweep with `addedToDirectoryDateKey`, inbox-marker keep-set. Thoughtful.
- **Honest reporting everywhere**: signed savings, "(capped)", three-state verdicts, measured re-encode passes. Rare and valuable.
- **CI**: tests gate the IPA jobs; unsigned path needs zero secrets.

---

## Addendum (round 3, release 1.2.0) — VideoToolbox capability audit

Audit of the framework's documented feature families vs. app coverage, driving release 1.2.0:

| VideoToolbox / AVFoundation capability | App status |
|---|---|
| Hardware H.264/HEVC encode, offline session, profiles (Main/Main10) | ✅ covered since v1 |
| Pixel-transfer scaling (bit-depth preserving) | ✅ covered since v1 |
| HDR→SDR tone-map (composition), rotation preservation | ✅ covered since v1 |
| Target-size budget + measured re-encode passes | ✅ covered (VideoToolbox has no 2-pass/CRF on iOS) |
| **Trim** (`AVAssetReader.timeRange` bounds video AND audio) | ✅ **added 1.2.0** — setup-flow Adjust section (single video), filmstrip UI, session anchor moves to the window start, verifier samples the source inside the window |
| **User rotation** (track-transform composition) | ✅ **added 1.2.0** — 90/180/270 in display space; encoded pixels untouched, SDR path composes the rotation instead of double-applying |
| **Custom poster** (QuickTime artwork) | ✅ **added 1.2.0, reworked 1.2.1→1.2.3 per user** — the user chooses ANY image (Photos picker) in the Adjust section; it is normalized to JPEG ≤1024px and embedded as QuickTime artwork metadata (Files/players show it), the row thumbnail uses it, and the pick persists in the job record. (1.2.0's frame-pick and PNG-export variants were replaced — not what was wanted.) |
| ProRes output (`AVVideoCodecType.proRes422/.proRes4444`) | ⏳ deferred — supported on iOS but produces enormous files; fits an "editing handoff" preset, not a compressor's default set |
| Audio passthrough (nil outputSettings on reader/writer) | ⏳ deferred — avoids AAC generation loss, but MP4 muxing compatibility for non-AAC codecs needs per-format handling |
| Multi-track audio (keep all tracks) | ⏳ deferred — app intentionally takes the first track |
| Chapter markers / timed metadata | ⏳ deferred |
| Alpha-channel HEVC | ⏳ deferred (niche) |
| Decoder-side direct VT (VTDecompressionSession) | ✅ no gap — AVAssetReader is the right abstraction here |
| Batch analysis concurrency, stall watchdogs, bounded verification | ✅ covered in earlier rounds |

---

| Priority | Items |
|---|---|
| **P0 — this week** | B1 (setup-cancel leak), B2 (last-used preset), B3 (inbox race), B15 (README rewrite), B11 (plist keys) |
| **P1 — next release** | B4 (fullscreen → Split View), B5 (orientation), B6 (queue order), B7 (player dead-end), B8 (odd dims), UI‑1/2 (content width or split view), UI‑18 (report truncation), #30 (software encode toggle) |
| **P2 — polish** | UI‑3…UI‑29 as themed batches (drag & drop + keyboard; sample-encode preview; history management; a11y + string catalog), B9–B14, #32–#35 |

---

*Review method: full read of all 17 Swift source files (App/Engine/Models/Store/UI), 4 test files, `project.yml`, `ipa.yml`, `README.md`, asset catalog, and git history (`ad4a2bc` and prior 15 commits). No code was modified. Two source lines that the tooling masks as secrets were inspected byte-wise and are benign (`pretty(_ token: String)`; the CI keychain default). Compile/test verification must run on macOS/Xcode or the existing GitHub Actions workflow.*
