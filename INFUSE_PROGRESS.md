# Infuse episode progress returns

For the current review and corrections, see
[21 October release review](docs/krystian-validation-2026-10-21.md).
The following sections record earlier implementation stages.

Branch: `fix/infuse-episode-progress-sync`, based on `fix/home-startup-loading`.

## Diagnosis

The external callback already parsed both `progress` and `position`. The verified defects were downstream:

- `NuvioTVApp.handleExternalPlaybackCallback` consumed its durable session before validating data or checking persistence. Invalid callbacks and failed writes could therefore spend the only retry.
- Partial provider playback called `TraktProgressService.recordLocalPlayback` with `notify: false`. Details already subscribes to the provider notification, but did not receive it until a later remote response or navigation refresh.
- Completion used a stop report plus the manual watched-mark path, bypassing the built-in player's idempotent completion ID/outbox.
- Local progress/checkpoint APIs discarded persistence failures. Deferred watched cleanup also read the active profile after scheduling.

## Implementation

- `PlayerModels.swift`: validate returns before acknowledgement, retain failed writes for redelivery, capture profile/source/account/session time, reject superseded session IDs and newer same-episode state, and route successful persistence through existing progress/history services.
- `NuvioTVApp.swift`: delegate callback processing; capture launch ownership and prefer an existing exact-episode ledger duration over metadata runtime. Launch URLs, subtitles and resume arguments are unchanged.
- `CatalogModels.swift`: return verified write results from progress persistence; preserve normal built-in write deduplication; bind deferred watched cleanup to its original profile.
- `TraktAuthService.swift`: commit provider checkpoints before publishing them and return persistence success. Partial external playback now requests the existing notification immediately.
- `DetailsScreen.swift`: expose the existing episode presentation cache types to unit tests. No rendering, selection, scrolling or focus behavior changes.

Completion uses the existing 90% boundary, or MDBList's existing boundary when selected. The exact content ID/season/episode is passed to `recordPlaybackCompletion`; there are no bulk season/series operations. Local watched notifications update badges without waiting for a provider. Partial progress below the boundary retains seconds/duration and emits the existing progress notification after successful storage. The minimum sample remains ten seconds and the existing local runtime minimum remains sixty seconds.

Nuvio Sync retains its existing per-episode keys and payload. Normal watched/progress notifications schedule existing uploads; pending ledger rows and watched completion events retain their existing merge protection. Trakt/MDBList partial positions use provider checkpoints and reporting, without writing a second Nuvio progress row. Trakt completion uses the existing completion outbox rather than an additional stop scrobble. Nuvio Sync may mirror watched history to connected Trakt under existing settings; partial resume positions are not mirrored between independent providers.

The shared mobile `WatchProgressModels.kt` and tvOS ledger mappings were inspected; no mobile, macOS or backend source was changed.

## Limits and manual checks

[Firecore's API documentation](https://support.firecore.com/hc/en-us/articles/215090997-API-for-Third-Party-Apps-Services) documents `position` in seconds and `lastPlayedUrl` on success, once when playback ends or closes. It does not promise duration or a fractional `progress` value. The existing fraction compatibility remains, and a supplied duration is accepted, but a position still needs a known runtime. Missing/invalid data, a missing callback, an unavailable selected provider or a wrong profile leave state untouched. Foregrounding alone never proves playback or completion. Runtime accuracy depends on existing metadata or previously measured progress; the callback cannot prove that an estimated metadata runtime is exact.

Failed local persistence retains the session for callback redelivery; it does not fabricate an automatic retry sample. Provider delivery/offline retry capabilities remain those of the existing services. A partial provider checkpoint protects immediate local display but is not a new durable network outbox. Cross-device confirmation requires live accounts and compatible provider settings on each client.

Physical Apple TV/Infuse and iOS/macOS validation has not been performed. No device deployment was requested. After review and an explicitly requested deployment:

1. Select Nuvio Sync on all clients. Play S01E03 to completion in Infuse and return; only E03 should gain a badge. Repeat at 95%. Restart and sync; the mark must remain.
2. Return at about 45% of S02E02. Check its bar immediately, unchanged season/scroll/focus, and the exact resume position. S02E03 must be unchanged. Resume E02 on mobile/macOS after sync.
3. Complete S01E08 with earlier episodes skipped; no skipped episode or Season 2 should become watched.
4. Repeat with Trakt selected on each client, then MDBList where supported. Check provider history for one completion and exact-episode resume. Do not expect partial progress to cross between Nuvio Sync and Trakt modes.
5. Return without a callback, trigger an Infuse error, and switch profiles before a delayed return. Verify no invented progress or cross-profile mutation. Check remote playback made after the original handoff is not rolled back.
6. With slow/offline networking, confirm local indicators update without a Home round trip; reconnect and inspect the selected provider. Confirm stream-picker Refresh, built-in resume, and Siri Remote focus restoration still behave normally.

## Validation results

Final source state: **81 focused simulator tests passed, zero failures**, Xcode 27.1, tvOS 27.0 simulator. This includes ten new regression tests. The unsigned generic tvOS device build also succeeded. `git diff --check` passed.

Executed suites: `ExternalPlaybackReturnTests`, `ContinueWatchingAndPlayerSyncTests`, `HomeStartupGateTests`, `TraktContinueWatchingOwnershipTests`; plus `PlaybackBackendPolicyTests` cases `testWatchedEpisodeLeavesOtherEpisodesInProgress`, `testOlderRemoteProgressCannotOverwriteNewerEpisodeResume`, `testWatchedEpisodeClearsTheLedgerRowBehindTheProgressBar`, and `testSaveProgressCountsCompletionsPerEpisode`.

The tests cover 100%/95% completion, 45% partial progress, missing/malformed/untrackable samples, explicit failure, duplicate and old-session callbacks, wrong-profile isolation, injected persistence failure and retry, immediate notifications, exact-episode persistence/reload, stale Nuvio/provider data, and stable Details selection revisions. They use isolated test profiles and callback stores, with no real-account writes. Cache-level selection preservation is automated; actual Siri Remote focus and scroll rendering remain manual checks.

The older `StreamQualityTagsTests` and `DetailsViewModelTests` files are excluded by the existing project configuration. New callback tests live in the runnable dedicated file; no passing result is claimed for those excluded suites.
