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
