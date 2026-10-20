# Nuvio-K release preparation — 20 October 2026

Prepared version: **3.4.5 (77)**, replacing observed **3.4.5 (76)**.
Development branch: `fix/infuse-return-progress-reliability`.
Review baseline: `6a6ff1371e6bab029517362c87846ccdc132fd57`.
The final commit mapping and checksums are retained in the private manifest.
No physical-device installation, launch, deletion or provisioning change was performed.

## Reviewed changes

- Infuse handoffs and returned callbacks use an atomic file journal, preserving
  profile/session/episode/stream identity and pending returns across restarts.
  A failed durable write prevents the external handoff; pending returns cannot
  be replaced by another session. Superseded returns are consumed without
  reporting saved progress.
- Exact seconds survive unknown duration and app restarts. Only exact external
  checkpoints receive extended lifetime; ordinary optimistic checkpoints retain
  expiry. Legacy estimated runtimes cannot establish Infuse completion.
- Home, Details and manual selection preserve percentage-only progress for
  conversion after actual stream duration becomes available. Explicit restart
  sends position zero; omitted seconds preserve the external player's resume.
  Resume state is scoped to the selected episode and cleared between routes.
- URL comparison accepts equivalent unreserved encoding, host/scheme case and
  default ports without dropping query parameters, credentials or reserved delimiters.
- Newer provider progress, including rewinds, and matching watched marks reconcile
  local checkpoints. Infuse returns avoid duplicate Trakt completion uploads and
  scrobbles while retaining other provider behavior.
- Selective upstream PRs 304–307 and their regressions remain present. PR 308
  was inspected for exclusion and was not integrated. Existing release dates,
  stream selection, startup behavior, branding and provider separation remain.

## Executed validation

- Clean full simulator run: **1,275 passed, zero failures**.
- After the final checkpoint-pruning optimization: **95 affected tests passed,
  zero failures** (external return, Continue Watching/player sync, Trakt ownership,
  Home startup). The full run precedes that small final change; it is not relabeled
  as a second full run on final source.
- Final clean signed generic tvOS device build passed.
- Build/installer helper: **41 tests passed**, including mocked failure, stale
  artifact, signing/provisioning, privacy and deployment-gate cases.
- Plist and shell syntax checks passed; Git whitespace checks passed.
- Xcode **27.1 (27A9275)**, Tuist **4.207.0**, tvOS **27.0** simulator.
- Real helper doctor, status/report, workspace reuse, artifact verification and
  preparation reuse checked. Physical installer behavior tested only with mocks.

Five existing test files remain excluded by project configuration:
`CatalogDecodingTests`, `DetailsViewModelTests`, `PerformanceTests`,
`RustSDKIntegrationTests`, `StreamQualityTagsTests`. UI tests were not executed;
they require fixtures. Existing Swift concurrency and metadata warnings remain.
Live Infuse/Trakt/network behavior and Siri Remote focus require device acceptance
checks after separately authorized installation.

## Signing and compatibility

App `com.krystian.nuvio`, extension `com.krystian.nuvio.TopShelf`, group
`group.com.krystian.nuvio`, and callback scheme `nuvio-krystian` verified.
Both signatures pass strict verification; certificates are current and authorized
by embedded profiles; both profiles authorize the privately configured target.
The earliest embedded profile expires **26 October 2026, 23:56:28 UTC / UK time**
(Top Shelf); the app profile expires at **23:57:05**. No renewal is assumed.

The prior read-only inventory confirmed the expected installed bundle/build and
separate `Nuvio.Sideload`. It did not expose the installed signing identity, so
signing continuity and data retention cannot be guaranteed from that query.
The later installer stops on a known mismatch or any verification/install failure,
never uninstalls, and has no reinstall fallback. The original app is not targeted.

## Remaining practical limits and handover

Durationless callbacks preserve seconds but cannot prove completion. The existing
minimum playback threshold remains. Provider reconciliation uses timestamp ordering
with a 30-second skew allowance; it cannot identify cross-device sessions perfectly.
Settings, accounts, sources, live resume and focus still need acceptance checks.

Use `python3 scripts/krystian_build.py status --json` to resume work.
See [CODEX_WORKFLOW.md](CODEX_WORKFLOW.md) for private storage, cache validity,
focused tests and the separately gated future update procedure. Do not invoke the
installer until the human explicitly says GO. No deployment authorization is
implied by a successful build, package or this report.
