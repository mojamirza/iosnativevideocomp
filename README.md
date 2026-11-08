# VidCompress — Native iPadOS Video Compressor

A professional, **100% native** (no external frameworks) iPad video compressor written in **Swift + SwiftUI** — VideoToolbox all the way down.

| Layer | Technology |
|---|---|
| UI | SwiftUI (iPad-first) |
| Media I/O | `AVFoundation` (AVAssetReader / AVAssetWriter; PhotosPicker + document picker) |
| Encoding | **VideoToolbox** — AVAssetWriter drives VT directly (profiles, GOP, average bitrate) |
| Scaling | VideoToolbox pixel-transfer sessions (rotation-aware, bit-depth preserving) |
| HDR → SDR (opt-in) | AVFoundation video composition — system tone-map, primaries conversion, scale & rotation in one pipeline |
| Persistence | **SwiftData** (compression history) |

## The three differentiators

### 1. Color-safe engine
`Sources/Engine/VideoProbe.swift`, `CompressionEngine.swift`
- Reads the source track's **color primaries / transfer function / YCbCr matrix** and canonicalises them onto real SDK constants in **one** resolver — buffer attachments and writer settings can never disagree.
- Every decoded pixel buffer is **re-tagged** with the source metadata (Core Video attachments) before it reaches the encoder, and the output mux carries the same tags (`AVVideoColorPropertiesKey`). Rec.709, Rec.2020 and P3 files stay exactly as they were.
- **Bit-depth aware**: 10-bit and HDR (HLG/PQ) sources decode to **10-bit YCbCr** and encode as **HEVC Main10** — requested explicitly, then re-parsed from the output's own hvcC atom by the verifier (verify, don't trust). Never tonemapped, never squeezed through an 8-bit intermediate.
- **HDR → SDR conversion is opt-in** (preset-level): an AVFoundation video composition declared Rec.709 tone-maps the source (HLG or PQ), converts the primaries, scales and rotation-bakes the render in one system pipeline — no custom kernels. Downscaling on this path **scales via a layer-instruction transform** (shrinking `renderSize` alone would crop the canvas), and the writer receives no stale source-format hint.
- The verifier **fails the report** if color metadata drifts on an HDR source.

### 2. Honest size planning
`Sources/Engine/SizeMath.swift`, `QualitySizeOptimizer.swift`
- Two rate modes: **fixed Mbps** — always capped at ~95 % of the source's own bitrate (a re-encode never inflates a file; the UI says "(capped)") — or a **guaranteed target size in MB**.
- The target guarantee is enforced by **measurement**: the bitrate is solved from the budget (target − container overhead − audio, aimed at 95 %), the real bytes of the finished pass are measured, and the encode re-runs (up to twice) with a corrected rate. The verifier's "Target size honored" item is the final word.
- Every live estimate — setup sheet, preset rows, editor — runs the **same `plan()`** the encoder runs, container overhead included, so the number on screen is the number the job runs with.
- Feasibility is checked per video **before** any encode starts ("Too small" in the preset row).

### 3. Output integrity report
`Sources/Engine/IntegrityVerifier.swift`, `QualityCheck.swift`
- After **every** encode the output is re-opened and actually verified: duration conservation, track presence, **decode spot-checks** (first + late frames), audio conservation, **color metadata**, **bit depth**, privacy, bitrate sanity and target size.
- A **PSNR/SSIM quality score** is computed from real decoded luma frames of source vs output at matched timestamps (anchor-corrected for trimmed sources).
- Three-state verdict — ✓ verified / ⚠ warnings / ✗ failed — warnings never masquerade as a pass. One tap → the full checklist.

## Feature map

- **Presets**: 5 built-ins (High quality keep-resolution HEVC 8 Mbps · Medium 720p 4 Mbps · Low 480p 1.5 Mbps · Lecture small 720p · Lecture sharp 1080p) + a full custom editor — codec (HEVC / H.264), resolution class (keep … 4K), **fixed bitrate** (log slider + exact typed value) or **guaranteed MB target**, fps cap, audio bitrate, mono voice track, HDR→SDR. Live per-preset estimated output size and quality hints. Presets persist; the last-used selection sticks.
- **Encoder**: hardware VideoToolbox — the only selectable video encoder on iOS (a software-encoder request crashes the writer on device; verified). The quality levers are the offline session, Main10 for HDR, and measured re-encode passes.
- **Import**: PhotosPicker (original pixels — `preferredItemEncoding: .current`, so the picker never pre-transcodes HDR), the Files app picker and **drag & drop** in Split View, all multi-select for batches; plus a **Shortcuts action** ("Compress video") that hands videos to the queue. Multitasking (Split View / Stage Manager, all four orientations) is fully supported.
- **Adjust (single video)**: rotate (90°/180°/270°, display-space track transform — pixels untouched), **trim** (bounds the read to the selected window), and a **custom poster** — choose any image from your library; it is embedded as QuickTime artwork in the output. Note: the Photos app always generates its own video preview and ignores embedded artwork — the poster shows in Files on a Mac, VLC, Plex and similar players, and the in-app integrity report verifies it was embedded.
- **Queue & history**: live progress with encode speed/ETA, cancel, retry, swipe-to-delete, **multi-select with batch save to Photos / batch delete**, SwiftData-backed history with per-job savings, in-app player with **source/output comparison at the same timestamp**.
- **Menu bar (iPadOS 26 windowed mode)**: Import / Queue / Help menus beside the system menus — ⌘O import from Files, ⇧⌘N new preset, ⌘. cancel active job, Clear Finished… (confirmed), About & Settings sheet with the privacy toggle. No custom "File" menu: iPadOS shows the system File menu separately rather than merging, which duplicated it.
- **Background compression** (iOS 26+): encodes keep running when you leave the app with progress on the system indicator; a revoked task turns its jobs into retryable rows — never silent loss.
- **Privacy scrub**: outputs never carry location metadata; the creation date is kept by default (toggle in setup). If a muxer ever refuses the date item, the encode retries once without metadata rather than failing the job.
- **Storage**: outputs land in the app's Files folder (On My iPad → VidCompress) and are excluded from iCloud backups; import copies live in Application Support (also excluded from backups — never in purgeable Caches, so a queued batch can't be silently wiped by the system) and encode scratch lives in Caches, cleaned automatically (including on cancelled setups).

## Project layout

```
project.yml                     XcodeGen spec (generates VidCompress.xcodeproj)
Sources/
  App/VidCompressApp.swift      entry point + ModelContainer
  App/BackgroundCompress.swift  iOS 26 BGContinuedProcessingTask lifeline
  App/CompressVideoIntent.swift Shortcuts intent + VideoInbox handoff
  Models/                       Preset, IntegrityReport, SwiftData JobRecord
  Engine/
    VideoProbe.swift            probe + ColorTags (color-safe core) + SessionAnchor
    QualitySizeOptimizer.swift  bitrate planning
    SizeMath.swift              THE one target-size/bitrate/expected-bytes formula
    CompressionEngine.swift     Reader → (composition | VT pixel transfer) → VideoToolbox
    IntegrityVerifier.swift     post-encode verification
    QualityCheck.swift          PSNR/SSIM luma sampling
    PrivacyScrub.swift          metadata policy + session kill switch
    AsyncTimeout.swift          watchdogs / bounded async races
  Store/JobCoordinator.swift    queue, progress, cancel, SwiftData records
  UI/                           RootView, SetupFlow, JobRows, PresetViews
Tests/                          SizeMath, Plan, QualityMath, ColorTags (CI-runnable)
.github/workflows/ipa.yml       CI: unit tests + unsigned/signed IPA on every push
```

## Build the app locally

1. Requires a Mac with Xcode 26+ (the background-compression APIs ship only in the iOS 26 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. `xcodegen generate`
3. Open `VidCompress.xcodeproj`, set your **Team** in the target's Signing & Capabilities, then Run on an iPad / iPad simulator.

## Build an IPA with GitHub Actions

The workflow `.github/workflows/ipa.yml` runs the unit tests first, then produces
**`VidCompress-unsigned.ipa`** (artifact) with **no secrets required** — re-sign it
later with Sideloadly / AltStore / Apple Configurator.

For a **signed, installable IPA** set the following repo *secrets*
(Settings → Secrets and variables → Actions → New repository secret):

| Secret | Value |
|---|---|
| `IOS_P12_BASE64` | your Apple Distribution signing certificate, base64 (`base64 -i Certificates.p12`) |
| `IOS_P12_PASSWORD` | the p12 export password |
| `KEYCHAIN_PASSWORD` | any strong throwaway string for the CI keychain |
| `IOS_TEAM_ID` | your 10-char Apple Developer Team ID |
| `IOS_PROVISIONING_PROFILE_BASE64` | an **ad-hoc** provisioning profile embedding your device UDIDs, base64 |
| `ENABLE_SIGNED_IPA` (repository **variable**) | `true` |

Then run the workflow manually (workflow_dispatch) to get the signed IPA artifact.

### ⚠️ About the GitHub token shared in chat
A personal-access token was pasted into the conversation. Treat it as **compromised**:
1. Revoke it: GitHub → **Settings → Developer settings → Personal access tokens → delete**.
2. Regenerate a new fine-grained token. Never commit tokens to the repo — store them as **secrets**, and use `git push` with the token kept in shell env vars, never written into files.

## Changelog

### v1.8.3 — build 29 (scroll fix for many cards)

- Swipe-to-delete's drag gesture was attached with `.simultaneousGesture`, so every finished card ran a drag recognizer alongside the scroll view's pan. With a long list, the recognizers fought: vertical drags that started ON a card stalled instead of scrolling, and only touches on the background between cards scrolled. The gesture is now exclusive (`.gesture`) — SwiftUI's ScrollView resolves by direction: vertical drags scroll (from anywhere, cards included), horizontal drags swipe the card.

### v1.8.2 — build 28 (no more card churn during encodes)

- The ⋯ menu (and every finished card) visibly “ticked” while a compression ran: progress ticks republish the whole `jobs` array twice a second, and each tick re-rendered EVERY card — including unchanged finished ones — which on iPadOS 26 made the ⋯ menu flash like a lightbulb. Cards now skip re-renders when nothing they render changed: `Job` is `Equatable` and `JobRowView` compares `job` + the three coordinator values it renders (selection mode, own selection, queued count) instead of subscribing to the whole coordinator. The encoding card still updates live; unchanged cards are left completely untouched.

### v1.8.1 — build 27 (deep re-review fixes)

Full folder-by-folder re-review (App, Engine, Models, Store, UI, Tests). Three fixes from it:
- Privacy scrub: the ENCODER now writes metadata by the enqueue-time policy snapshot — the verifier already judged files by it, so a mid-queue toggle of "keep creation date"/"strip all" silently diverged encoder and verifier and produced false "date dropped" warnings on the rest of a batch.
- Renaming an output refreshes the row's cached file-existence flags (the file moved; stale flags pointed row actions at the old path).
- The preset manager's delete confirmation is an alert (consistent with every other destructive prompt after the dialog-anchoring failures).

Everything else verified sound in the pass: queue worker/BG-driver handoff and claim ordering, cancel/retry/delete paths, scratch promotion and sweeps, legacy storage migration, the AAC ladder + 48 kHz fallback, FrameCapper cadence (incl. unit tests), SessionAnchor probe/engine agreement, verifier checks (duration/decode/color/bit-depth/privacy/target-size/quality mapping), trim math, stall watchdogs, Shortcuts handoff (atomic markers, orphan sweep keep-set), and the notification gating.

### v1.8.0 — build 26 (design direction round)

**Identity & hierarchy**
- Brand accent: a new AccentColor asset (matched to the app icon's blue, lighter in dark mode) re-tints `.tint` app-wide; AppTheme exposes `Color.appAccent`.
- Hero stat: “Saved 4.2 GB” now lives at the top of History on the main screen (it was sidebar-only, invisible on compact widths).
- Done rows lead with a green savings pill (−62% / +8% when the output grew); the struck-through size-first line is gone. The verdict icon is its own VoiceOver element (“Verified” / “Passed with warnings” / “Failed”), with labeled pill and sizes.
- Narrow widths (1/3 Split View) drop the save/share buttons on done rows — save+share+⋯ starved the title next to a 74 pt thumbnail; the same actions live in the ⋯ and context menus.

**Setup sheet**
- Presets collapse to the selected one + “Change…” — the size estimate and Compress sit above the fold instead of behind 5+ preset rows; selecting a row collapses back.

**Correctness fixes (from the review)**
- Source/Output compare now TRANSLATES the playhead on trimmed jobs (output 0:00 == source startOffset + trimStart) — the toggle showed a different scene before.
- ETA/speed restart on a target-size re-encode pass (startedAt resets), and the row says “Re-encoding to fit…” instead of silently running a second pass.
- Resizing the window across the compact threshold mid-setup no longer destroys the import copies (the shell swap fired onDismiss while the sheet was still up).
- One honest size delta everywhere: growth reads “+8%”, sub-percent deltas read “−<1%” — never a hidden or lying “−0%” (setup bar, batch line, editor estimate, done-row pill).
- Trim strip: four named VoiceOver actions (Start earlier/later, End earlier/later) replace the single whole-window adjustable action.
- Library imports get human names: “Video 2026-11-08 14.32.10” instead of IMG-<UUID>; the import card reads “Video 2 of 5”.
- Shared duration formatter: h:mm:ss above an hour (was “125:30”) and the report's encode time no longer prints raw seconds.
- Strip-all disables the inert “Keep creation date” toggle (settings + preset manager) and explains why; the settings sheet reads PrivacyScrub's key.
- Preset manager, editor and settings sheets now sit on the pinned canvas with card-token rows (the manager was the one screen on system gray).
- Root-level destructive confirmations are alerts (no iPad anchoring artifacts).

### v1.7.4 — build 25 (Pause removed · separated cards back)

**Pause — removed.** The user-facing Pause feature is gone, deliberately: across v1.7.0–v1.7.3 it never behaved dependably on device (tap delivery and stop-the-encode semantics never lined up for real use), and stopping work is fully covered by per-row Cancel (with confirmation), the Queue menu's Cancel Active/All Jobs, and the ⋯ menu. The queue status bar remains as a passive live readout (what's encoding, overall %, jobs in flight). The SYSTEM pause (iOS revoking the background task) is untouched — that one is essential and machine-driven.

**Queue screen — the v1.6.3 presentation is back, by request:**
- Separated rounded cards on the AMOLED canvas again (not grouped list rows), card-era section headers (tinted icon + count capsule), queue bar and import card as cards.
- The big Photos / Files buttons in the empty state sit SIDE BY SIDE again (custom layout, not ContentUnavailableView, whose actions stack).
- Swipe-to-delete is the proven custom modifier from v1.6.3; the destructive confirmation still presents from the root level (pendingDeleteID/pendingCancelID) so the fat-finger step can never be skipped.
- Kept: every engine fix (atomic Shortcut handoff, single BG driver, fps re-anchor, 48 kHz audio fallback, Application-Support imports, privacy snapshot), the verified record deletion, and the root-level destructive confirmations.

### v1.7.3 — build 24 (swipe/delete reliability + crash fix)

Three device-reported issues around the new swipe-to-delete, all rooted in presenting destructive confirmations FROM INSIDE List rows:
- Swipe delete skipped the fat-finger confirmation and behaved erratically: a `confirmationDialog` presented from a mid-swipe List row is not reliably anchored on iPadOS 26 — it silently failed. Destructive intents (swipe, ⋯ menu, action buttons) now only ARM a pending request on the coordinator; the confirmation presents from the ROOT LIST with a stable anchor. Applies to Stop/Remove-from-queue too.
- Crash when adding a video after a delete + deleted row reappearing after relaunch: the SwiftData record removal could fail silently (`try? save`), leaving a half-deleted record in the context — the next insert then crashed, and the record survived relaunches. `removeRecord` now DELETE + SAVE + VERIFY (with one retry) and all record saves log failures loudly instead of swallowing them.
- The row-wide `contentShape(Rectangle())` tap target (v1.7.1 selection fix) interfered with the List's native swipe gestures — it is now applied ONLY in selection mode, where swipes are disabled anyway.
- The queue screen no longer flips containers between List and ScrollView on the empty↔populated transition (that flip sat exactly on the reported delete→add crash path): the empty state is an overlay over the always-present List.

### v1.7.2 — build 23 (Pause actually stops the encode)

- Pause now stops the queue WHERE IT STANDS: the in-flight encode is cancelled and its job returns to the queue (partial output discarded — VideoToolbox cannot resume a half-written file), so Resume restarts it fresh. The old semantics ("let the in-flight job finish") read on device as a broken button: the progress bar kept climbing through the tap.
- A pause that lands during (uncancellable) verification keeps the finished result instead of discarding it; pause-aborts surfacing through engine teardown error paths re-queue instead of failing.
- Queue bar: paused state reads "Queue N% · paused" with a selection haptic on the tap, so the button's registration is immediately visible and tangible.

### v1.7.1 — build 22 (interaction fixes for the v1.7.0 List conversion)

Three device-reported regressions, all traced to controls living inside List rows:
- Empty state: the big Photos/Files buttons didn't work — `ContentUnavailableView` is designed as a scroll view's ROOT, not a List row (layout collapses, bordered-style actions don't reliably receive taps on iPadOS 26). It now owns a plain ScrollView branch when the queue is empty; the buttons work there.
- Pause: the queue bar's `.bordered` Pause control sat in a List row and didn't register taps. The bar is now PINNED above the List via `safeAreaInset` — a plain SwiftUI tap target that also stays visible while history scrolls.
- Selection taps missed at the trailing end of a row: rows lost their card background in the List conversion, and a tap gesture without an explicit `contentShape` only hit-tests rendered content — the transparent trailing spacer fell through. Rows now declare `.contentShape(Rectangle())`, so the full row width toggles selection (child buttons still win in their own bounds).

### v1.7.0 — build 21 (Apple-design pass + engine hardening)

**Engine / backend**
- Shortcuts handoff: the inbox marker is written ATOMICALLY — a half-written marker could be read as corrupt, deleted, and the video silently never enqueued.
- Shortcuts action description now matches behavior ("your last-used preset", not a fixed built-in).
- Background driver: a second delivered BG task can no longer start a second driver loop (two concurrent encodes were possible via the 60 s stale-submit path).
- FrameCapper re-anchors after ONE period of lag (was two) — matching its documented intent; VFR bursts no longer keep a few frames over the cap.
- Audio: a source whose sample rate the AAC encoder rejects (e.g. 96 kHz recordings) no longer ships SILENT — a last-chance 48 kHz resample runs (reader and writer rates pinned together).
- Queued/failed jobs can no longer be silently wiped by iOS: import copies moved from purgeable Caches to Application Support (excluded from backups, legacy locations migrated). If rows are ever purged anyway, a notice explains it instead of silence.
- Unreadable Shortcuts videos surface a notice instead of being removed without feedback.
- The integrity verifier reads the privacy policy SNAPSHOT taken at enqueue time (a mid-queue toggle no longer produces false "date dropped" warnings).

**UI / design (Apple HIG alignment)**
- Queue rebuilt as a native inset-grouped List: system swipe-to-delete, section headers/footers, native row animation — the hand-rolled swipe modifier is gone.
- Native `ContentUnavailableView` empty state; HIG-style section headers; semantic SwiftUI colors everywhere (no UIColor bridges).
- Row actions are native icon buttons with 44 pt targets; context menus on rows; consistent SF Symbols and list typography (body titles, footnote subtitles, monospaced digits).
- Preset rows use the modern `circle.inset.filled` selection glyph; setup sheet uses Apple's grouped-list header style.

### v1.6.3 — build 20
- Compact drawer: main page first, swipe both ways between main page and sidebar.

## Known design decisions

- Container is **MP4 (H.264/HEVC)**; HDR sources keep their resolution by default and are never tonemapped unless the preset explicitly converts to SDR.
- Audio is re-encoded to AAC at the preset's budget (channel-aware ladder that only steps down; ships without audio only when no AAC configuration validates) instead of stream copy, for consistent A/V muxing.
- Jobs run one at a time (stable memory footprint on older iPads).
- VideoToolbox on iOS has no true 2-pass or CRF mode; the guaranteed-target mode implements the equivalent by **measuring real output bytes and re-encoding with a corrected rate** (up to two passes).
- The complexity heuristic of earlier pre-release builds (per-frame Core Image analysis) was removed in favour of predictable, honest planning from the source's own data rate.
