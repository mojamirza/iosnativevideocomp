# VidCompress — Native iPadOS Video Compressor

A simple but professional, **100% native** (no external frameworks) iPad video compressor written in **Swift + SwiftUI**.

| Layer | Technology |
|---|---|
| UI | SwiftUI (iPad-first) |
| Media I/O | `import AVFoundation` (AVAssetReader / AVAssetWriter, PhotosPicker + document picker) |
| Encoding | **VideoToolbox** — AVAssetWriter feeds VT directly (`AVVideoCompressionPropertiesKey`, profile levels, GOP, bitrate) |
| Per-frame analysis | **Core Image + Core Video** (luminance maps, complexity scoring, Lanczos scaling) |
| Persistence | **SwiftData** (compression history) |

## The three differentiators (vs. Kompresso & friends)

### 1. Color-safe engine
`Sources/Engine/VideoProbe.swift`, `CompressionEngine.swift`
- Reads the source track's **color primaries / transfer function / YCbCr matrix** from its format description.
- Every decoded pixel buffer is **re-tagged** with the exact source metadata (Core Video attachments) before it reaches the encoder.
- The output mux carries **the same tags** (`AVVideoColorPropertiesKey`), so Rec.709, Rec.2020 and P3 files stay exactly as they were.
- **Bit-depth aware**: 10-bit and HDR (HLG/PQ) sources decode to **10-bit YCbCr** (HEVC picks Main10 automatically) — they are never tonemapped and never squeezed through an 8-bit intermediate. 10-bit/HDR/rotated sources keep their resolution rather than risk color or orientation damage (noted in the optimizer rationale). The verifier even fails the report if color metadata drifts.

### 2. Quality–size optimizer
`Sources/Engine/ComplexityAnalyzer.swift`, `QualitySizeOptimizer.swift`
- Before compression, ~16 frames sampled evenly across the video are decoded and measured via Core Image: per-frame **spatial detail** (luminance σ) + **motion** (mean abs luminance delta).
- The score adapts the bitrate: `bits = pixels·fps·bpp(quality goal)·codec factor·(0.62 + 0.75·complexity)`.
- Three goals: *Smallest / Balanced / Best*, **fixed Mbps**, or an **exact target file size (MB)** — the audio budget is reserved first, then the video bitrate is derived.
- Never allocates more than the source bitrate (no "compressed" files bigger than the original).

### 3. Output integrity report
`Sources/Engine/IntegrityVerifier.swift`
- After **every** encode the output is re-opened and actually verified: duration conservation (±1 % or 0.35 s), track presence, **decode spot-check of first + late frames**, audio conservation, **color metadata preservation**, bitrate sanity, measured savings.
- One tap → full checklist with ✓ / ⚠ / ✗ per check. Present it to the user instead of a blind "Done".

## Feature map

- **Detailed presets** with output size & bitrate: 8 built-ins (adaptive ×3, 4K/1080p/720p HEVC, 1080p H.264 for compatibility, half-size) + a custom preset editor (codec, resolution class, adaptive tier / fixed Mbps / MB size target, fps cap, audio kbps). Live **estimated output size** per preset, per source.
- **File selection**: `PhotosPicker` (library) + `UIDocumentPickerViewController`-backed `fileImporter` (Files app), both copies into a private Imports folder.
- **Compressing rows**: live progress + **Cancel**, queued/analyzing states, **error display**, Retry, Delete, Share, SwiftData-backed History.
- Everything saved **locally** (Documents/Compressed) with SwiftData history records.

## Project layout

```
project.yml                     XcodeGen spec (generates VidCompress.xcodeproj)
Sources/
  App/VidCompressApp.swift      entry point + ModelContainer
  Models/                       Preset, IntegrityReport, SwiftData JobRecord
  Engine/
    VideoProbe.swift            probe + ColorTags (color-safe core)
    ComplexityAnalyzer.swift    Core Image per-frame analysis
    QualitySizeOptimizer.swift  bitrate planning
    CompressionEngine.swift     Reader→CI→VideoToolbox pipeline (+cancel)
    IntegrityVerifier.swift     third pillar
  Store/JobCoordinator.swift    queue, progress, cancel, SwiftData records
  UI/                           RootView, SetupFlow, JobRows, PresetViews
.github/workflows/ipa.yml       CI: builds unsigned IPA on every push
```

## Build the app locally

1. Requires a Mac with Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. `xcodegen generate`
3. Open `VidCompress.xcodeproj`, set your **Team** in the target's Signing & Capabilities, then Run on an iPad / iPad simulator.

## Build an IPA with GitHub Actions

The workflow `.github/workflows/ipa.yml` fires on every push and produces
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

## Known design decisions

- Container is **MP4 (H.264/HEVC)**; HDR sources keep their resolution (never downscaled) to guarantee no tonemapping — the setup sheet annotates this.
- Audio is re-encoded to AAC at the preset's budget instead of stream copy, which simplifies consistent A/V muxing.
- Jobs run one at a time (stable memory footprint on older iPads); queued jobs show the standard cancel affordance.
- The complexity analyzer defaults to a "balanced" score if analyzing fails — it never blocks compression.
