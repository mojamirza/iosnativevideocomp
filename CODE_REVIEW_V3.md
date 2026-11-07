# Code Review V3 — 2026-11-07 (v1.5.0 / build 16)

Full pass over `Sources/` (App, Engine, Models, Store, UI), `Tests/`, `project.yml`
and `.github/workflows/ipa.yml`. Two user-visible items drove this round; both are
fixed here. Everything else below is what the pass found and what it confirmed good.

---

## 1. Fixed in this release

### P1 — Background turns gray in Split View / Stage Manager (the "two shades" bug)

**Symptom:** fullscreen dark mode is AMOLED black; in Split View "everything goes
brighter and the app background goes gray."

**Root cause:** Apple's dynamic dark-mode colors ship TWO shades per color — a
*base* one and an *elevated* one, resolved through
`UITraitCollection.userInterfaceLevel`. `systemBackground` is `#000000` at base
but `#1C1C1E` when the window resolves the **elevated** level — which is exactly
what an iPad app window gets in Split View / Stage Manager / windowed mode. The
grouped card surfaces brighten the same way (`secondarySystemGroupedBackground`
`#1C1C1E` → `#2C2C2E`, `tertiarySystemGroupedBackground` `#2C2C2E` → lighter).
The v1.4 AMOLED fix pinned dark mode to `systemBackground`, which is true black
at base — but the token still re-resolved to its elevated shade in windowed
contexts, so fullscreen vs Split View could never match.

**Fix:** the palette is now pinned to explicit RGBA components in
`Sources/UI/AppTheme.swift`, so nothing but dark/light can influence resolution:

| Token | Dark | Light | Replaces |
|---|---|---|---|
| `Color.appScreen` | `#000000` | `#F2F2F7` | dynamic `systemBackground` / `systemGroupedBackground` |
| `Color.appCard` | `#1C1C1E` | `#FFFFFF` | `Color(.secondarySystemGroupedBackground)` (9 call sites) |
| `Color.appTile` | `#2C2C2E` | `#F2F2F7` | `Color(.tertiarySystemGroupedBackground)` (probe grid) |

All 10 call sites across `RootView`, `JobRows`, `SetupFlow` were switched.
`Tests/AppThemeTests.swift` now pins every token at **both** trait levels
(`.base` and `.elevated`) for both styles, so this class of regression is
test-visible, not just visible.

### P1 — Sidebar redesign (was: two dead counters + settings)

The old sidebar ("Import" buttons, `Working: n / Finished: n` labels, About)
duplicated nothing useful and hid every queue control inside the detail column.

New structure (`Sources/UI/RootView.swift`):

- **Import** — Photos / Files pickers (unchanged, proven shape) with a
  drag-&-drop hint footer for Split View use.
- **Queue** — a *live* queue card: what's happening right now, overall queue
  progress bar, and a Pause/Resume control — the queue controls previously
  lived only at the top of the detail list and disappeared once you scrolled
  into history. Plus **Clear Finished…** (mirrors the menu-bar action, shares
  its confirmation dialog, disabled when there's nothing to clear).
- **Lifetime** — the "You've saved 12.4 GB" headline, visible wherever you are
  (collapsed entirely when history is empty).
- **App** — About & Settings (unchanged sheet host) with a version footer.

Supporting refactor: the queue summary math (active/finished sets, overall
progress, headline string) previously existed twice — in the in-list status
bar and in sidebar counters. It now lives **once** on `JobCoordinator`
(`activeJobs`, `finishedJobs`, `queueProgress`, `queueHeadline`) and both
surfaces read it; `LifetimeStats.summarize` is likewise shared by the sidebar
card and the list footer card.

### Housekeeping

- Version bumped to **1.5.0 (16)** in `project.yml`.
- `Tests/AppThemeTests.swift` rewritten for the pinned-palette contract.

---

## 2. Verified good (no change needed)

- **Cancellation ordering in the engine**: `EngineFlags` → cancel hooks → pipe
  serial-queue resumes (`ResumeBox`) → teardown before `finishWriting`; no
  append can race writer teardown, and `finishWriting` is never called on a
  cancelled/failed writer (hard crash otherwise). Correct as written.
- **Queue concurrency**: single worker + atomic claim out of `.queued` +
  worker generations make double-encoding impossible, including the
  wedged-verify `reviveWorker()` path and the BG-task driver deferring to the
  foreground worker.
- **Verify backstops**: per-job watchdogs (a Retry cannot cancel another
  job's), monotonic `systemUptime` deadlines, `forceVerifyTerminal` promotes
  the file so the record never points at swept scratch.
- **Queue persistence**: auto-resume bounded to one attempt (`autoResumed`),
  queued records resume, missing sources purge, dedupe pass for duplicate
  records, legacy storage migration before path derivation.
- **Free-space preflight** budgets 2× for target-size correction passes and
  fails before any bytes are written.
- **Import paths are OOM-safe**: no whole-file `Data` loads, FileRepresentation
  streaming, off-main copies, NSFileCoordinator for iCloud placeholders,
  security-scoped access handled, drop Data fallback written to temp.
- **Audio pipeline**: steps down only from the budget, mono/stereo explicit
  layouts, `canAdd` gate before attach (uncatchable-exception avoided), honest
  "ships without audio" + report warning.
- **Privacy scrub**: single creation-date item, no GPS path exists, session
  kill switch + verifier assertions, poster retry ladder.
- **Swift 6-ish hygiene**: locks around all `@unchecked Sendable` state
  (BGExpiryFlag, EngineFlags, StallWatchdog, OnceClaim, ResumeBox); no data
  races spotted.
- **CI workflow**: tests → unsigned IPA → (optional) signed IPA; Xcode 26
  selection with 16.4 fallback; artifact upload; no secrets in logs.

---

## 3. Open findings (recommendations, not fixed in this round)

1. **[P2] Compress isn't blocked when a target-size preset is infeasible for a
   batch video.** `PresetRow` shows "Too small" per video, but `canStart` only
   requires one valid probe; those jobs still run and can only fail at
   verification. Recommend disabling Compress (or auto-skipping rows) when
   `plan.targetFeasible == false` for any video that would be enqueued.
2. **[P2] Rotate the GitHub token pasted in chat.** It grants Actions read on
   this repo and must be treated as compromised (see README's token section):
   revoke it, store the replacement as a repo secret / local env var only.
3. **[P3] Retry's persisted state.** `retry()` flips the in-memory row to
   `.queued` but doesn't rewrite the record until `.compressing`
   (`markRecordState`); a kill in that narrow window restores the row as
   failed. Harmless (the row stays retryable) but a one-line
   `saveRecord(..., state: "queued")` would close it.
4. **[P3] Correction-pass swap order.** In `run()`, the target-size loop does
   `try? removeItem(output)` before `try moveItem(extra → output)`; if the
   move throws, the primary scratch is already gone and the failure surfaces
   as a generic error. Swapping to a move-then-delete (or move to a temp name
   first) would keep the last good file on a failed swap.
5. **[P3] `FrameCapper` comment/code mismatch.** The re-anchor comment says
   "more than a full period" but the threshold is 2 periods
   (`> 2.0 / cap`). Behavior is intentional and unit-tested; comment only.
6. **[P3] Lecture-mode id sharing.** The lecture variant copies the base
   preset's id, so a Shortcuts handoff resolving "last used" gets the
   un-tweaked base preset. Defensible ("habitual choice"), worth a comment at
   least.
7. **[P3] `StorageFooter.dirSize` is non-recursive.** Correct for today's flat
   directories; would silently under-report if subdirectories are ever added.
8. **[P4] `try!` on the in-memory `ModelContainer` fallback** (`VidCompressApp`).
   Cannot realistically fail; a `catch`-to-banner would still be tidier.

---

## 4. Test/build status

- Local review only (no macOS toolchain here); correctness enforced by CI:
  unit tests on the iOS simulator + unsigned IPA build on every push.
- Palette contract is enforced by `AppThemeTests` at both trait levels.
