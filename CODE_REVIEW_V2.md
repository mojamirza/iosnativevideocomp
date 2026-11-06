# VidCompress — Deep Re-Review (Round 2)

**Scope:** full codebase re-read at commit `1313625` — every source file, the four original test files plus three new ones, `project.yml`, CI workflow, and the six fix rounds stacked on `main` since the first review (`9859e1a` → `1313625`).
**Verification status:** CI for this exact commit is in flight while this document is written (watcher armed — result reported when it lands); everything up to `74c985c` is CI-green. Still no local compile (Windows machine) — CI remains the only build validation.

---

## 1. Where the project stands

Every finding from the first review and the two user-supplied review rounds is now closed, except the deliberately deferred "P2-big" features (§4). The implementation quality of the fixes themselves held up under this second pass — the new findings below are all Low/Info severity, none touch the engine's correctness pillars.

| Round | Items | Status |
|---|---|---|
| First review P0 | B1 leak · B2 last-used preset · B3 inbox race · B11 plist keys · B15 README | **closed** (`9859e1a`) |
| User review #1 | SDR crop→scale + format hint · quality-check anchor · haptic over-fire · PrivacyScrub hardening | **closed** (`9859e1a`, `b0666ab`, `7a7beab`) |
| User review #2 | RealTime key · `alwaysCopiesSampleData` · `shouldOptimizeForNetworkUse` · hint-on-re-encode · free-space preflight · NSFileCoordinator · history thumbnails · numericText animation · HDR option w/o probe · monotonic timing · SDRConvert dead code | **closed** (`6d28a9f`, `92af462`, `f7311c3`, `e182b95`, `74c985c`) |
| First review P1 | Fullscreen→multitasking · orientations · queue order · player dead-end · odd dims · content width · drag & drop · report truncation · software encoder | **closed** (`a53f6e3` + CI fixes) |
| First review P2 (this round) | Parallel batch analysis · queue position · report export + legend · VoiceOver container labels · Reduce Motion · selection haptic · drop-hint empty state · off-main storage footer · spelling unification · fps slider range · codec in filename stamp · budget-scaled quality sampling · CI fail-fast · 3 new test files | **closed** (`1313625`) |

---

## 2. New findings from this pass

All Low/Info. Nothing here blocks a release; they're recorded for the next hygiene pass.

**F1 (Low — inaccurate comment).** The fps-cap slider edit's comment claims legacy caps above 120 "collapse to 120 on save." Actually SwiftUI's `Slider` does not write the binding unless the user drags it — a stored cap of 240 is **preserved** on save (better than the comment claims). The behavior is right; the comment is wrong. *Fix: one comment line.*

**F2 (Low — documented edge).** In the odd-dimension path, if `makeTransferSession()` were to fail, `scaleNeeded` falls back to false while the writer geometry is already evened — the direct path would then append odd buffers against an even writer and the job fails with an honest encode error instead of "source-resolution passthrough" (what the comment above that line still promises). Session creation failing is vanishingly rare and the outcome is a clean failure, not corruption. *No action; comment nuance only.*

**F3 (Low — micro-perf).** `queuePositionLabel` filters + sorts the queued list on every render of a queued row. At realistic queue sizes (< 50) this is noise; if history ever grows into the hundreds of *queued* rows it's still trivial. *Note only.*

**F4 (Info — API limitation).** The software-encoder request cannot be verified at runtime: nothing in the produced file reveals which encoder ran, and AVFoundation offers no query. The editor copy is honest about this ("requests… honored on iOS 17.4+"), and the `#available` gate plus forward-compatible key handling mean there is no crash path. The definitive check remains a device A/B at low bitrate. *Documented; no action.*

> **ADDENDUM — F4 resolved by removal (device-verified).** The "no crash path" conclusion was wrong: with the request enabled, the app crashed on device with an uncatchable exception at writer setup. iOS AVAssetWriter does not honor an encoder specification that forbids hardware, and iOS ships no selectable software video encoder at all. The feature was removed entirely in 1.1.2(4) — model flag, engine specification, editor section, row chip, and its tests (a legacy-decode tolerance test keeps old stored presets loading).

**F5 (Info — cosmetic).** Drag & drop `Data` payloads are written to a `.mov`-suffixed temp file regardless of the actual container; AVFoundation sniffs the real container on open. The temp name may mislead in a debugger. *No action.*

**F6 (Low — UX nit).** `.sensoryFeedback(.selection, trigger: selectedPreset?.id)` also fires once when the setup sheet restores the initial preset (a single tick at open). Harmless; gate behind a "didRestore" flag if it ever bothers anyone.

**F7 (Info — by design).** Drop providers that deliver neither URL nor Data (rare in-memory movie representations) are skipped, and the batch surfaces the standard import-failure alert when nothing lands. Honest and consistent with the picker paths.

**F8 (Pending CI).** The new `SampleDescriptionTests` fabricate `CMFormatDescription`s with sample-description extension atoms via `CMVideoFormatDescriptionCreate`. This is expected to work (it's the documented extensions channel), but if CoreMedia rejects the synthetic atoms on the CI runtime, those tests will fail at `XCTUnwrap` and should be converted to skip-when-creation-fails. Watch the run.

---

## 3. What this pass re-verified (with fresh eyes)

- **Engine geometry restructure** (odd-dims + transfer-session ordering): `scaleNeeded` is now a `var` declared before geometry, forced true for odd stored dims *inside* the hint branch, the transfer session is created *after* geometry from the final flag, and the pool/adaptor/pipes all consume the finalized value. No ordering hazards found. 10-bit and rotated odd sources route correctly (stored dims are already the encoded frame; transposition only applies to the display-target path).
- **Queue pick order:** both workers and the BG subtitle now use the oldest-first rule consistently (`lastIndex`/`last` on the newest-first array). No other site depends on the old first-index behavior.
- **Parallel batch analysis:** bounded task group (width 4), URL captured before `addTask` (no `self` capture in the @Sendable closure), per-index results land on the main actor as each completes, failure counting preserved.
- **Free-space preflight:** fires after plan resolution (so target-size plans budget ×2 for the measured re-encode), throws before any byte is written, and flows into the standard failed-row path with a retry.
- **RootView refactor:** the three-layer chain (`interactiveList` → `presentedList` → `queueList`) preserves the original modifier semantics (alerts/sheets/tasks attached deeper in the hierarchy behave identically), and the seven extracted members are all state-correct.
- **iCloud coordination:** both import paths (document picker, Shortcuts stash) go through `NSFileCoordinator` + `.forUploading`; security-scoped access wraps it; plain local files pass through unchanged.
- **Accessibility:** the row uses `children: .contain` (not `.combine`) so the composed VoiceOver summary does *not* hide the action buttons — the first review's suggestion was subtly wrong and the implementation took the better shape.

---

## 4. Deliberately deferred (P2-big — each is a feature, not a fix)

1. **Sample-encode preview** (HandBrake's signature feature): encode a 5–10 s snippet at chosen settings, play source-vs-sample before committing. All machinery exists (engine + comparison player); needs setup-flow UI + a sample-plan variant.
2. **Live Activity / Dynamic Island** for active encodes (needs an ActivityKit widget extension target in `project.yml`).
3. **Local notifications** when the queue drains in the background.
4. **History search / sort / multi-select bulk actions** (bigger list-UI work).
5. **Frame-step compare mode** in the player.
6. **Queue reorder (drag) and pause** (gesture work; pause = finish current + hold).
7. **Localization via String Catalog** (~150 strings to externalize; mechanical but wide).
8. **App icon dark/tinted variants** (needs design assets).

## 5. On-device validation checklist (accumulated — CI cannot cover these)

- [ ] Dated clip with "Keep creation date" ON → report shows "Creation date preserved"; cross-check in Files → Get Info.
- [ ] HLG source at original size **and** at 720p + "Convert to SDR" → outputs scale (not crop) and match visually.
- [ ] Drag & drop from Files in Split View → setup flow opens; overlay shows while dragging.
- [ ] Software-encoder preset A/B at a low bitrate → compare quality at equal size.
- [ ] "This video is gone" path: delete an output in Files, open the row's player.
- [ ] Free-space preflight: attempt a large encode on a nearly-full disk → clear message, Retry offered.
- [ ] Background encode (iOS 26 device) survives leaving the app; revocation yields retryable rows.

---

*Method: full re-read of all 20 Swift files, both project configs, CI workflow, README, and the git log across the six fix rounds; byte-level inspection of the two tooling-masked lines (both benign); targeted greps for consistency (spelling, pick-order sites, member presence). No code was modified in this review pass.*
