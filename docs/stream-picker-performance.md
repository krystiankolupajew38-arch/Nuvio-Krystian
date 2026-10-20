# Stream picker refresh and responsiveness

## Report

Opening Play with configured add-ons can make remote navigation lag while sources arrive. Refresh was only exposed through a hold-Up gesture.

## Current upstream comparison (20 October 2026)

These references were fetched directly from the official repositories, rather than relying on inherited code in this fork:

- NuvioTV default branch `dev`, commit `ffe16251565d92026fae22dc671b3cec3eea4a7a`: [StreamScreen.kt](https://github.com/NuvioMedia/NuvioTV/blob/ffe16251565d92026fae22dc671b3cec3eea4a7a/app/src/main/java/com/nuvio/tv/ui/screens/stream/StreamScreen.kt) uses lazy rows and expands results based on the visible scroll position. [StreamScreenViewModel.kt](https://github.com/NuvioMedia/NuvioTV/blob/ffe16251565d92026fae22dc671b3cec3eea4a7a/app/src/main/java/com/nuvio/tv/ui/screens/stream/StreamScreenViewModel.kt) provides explicit refresh and builds stream badges on `Dispatchers.Default` in small batches.
- NuvioMobile default branch `cmp-rewrite`, commit `324afcffb962f1f7df45c5fa951131acec5a15a7`: [StreamsRepository.kt](https://github.com/NuvioMedia/NuvioMobile/blob/324afcffb962f1f7df45c5fa951131acec5a15a7/composeApp/src/commonMain/kotlin/com/nuvio/app/features/streams/StreamsRepository.kt) owns a background-dispatcher scope. [StreamsScreen.kt](https://github.com/NuvioMedia/NuvioMobile/blob/324afcffb962f1f7df45c5fa951131acec5a15a7/composeApp/src/commonMain/kotlin/com/nuvio/app/features/streams/StreamsScreen.kt) wires refresh to a repository reload and uses lazy rows.

These are default-branch snapshots, not a claim about the exact builds installed on a user's devices.

## tvOS changes

- Add a visible, remote-focusable Refresh control next to Sort. It restarts the current title/episode lookup, resets to All, and rejects repeated refreshes until completion. Hold-Up still works.
- Decode stream and manifest responses outside the repository's main actor. Stream requests bypass the local HTTP response cache; the existing app-level completed-request reuse remains intact.
- Run picker filtering and sort-key derivation on a serial background actor. Cancel superseded view tasks and discard their results before publishing UI state.
- Expand the initial 20-row page when focus reaches its final four rows. Remove appearance-driven expansion, which can mistake lazy-stack prefetch for user scrolling.
- Preserve the expanded page limit as additional provider results arrive, keeping the focused item materialized.
- Retain concurrent provider requests and progressive results, so slow providers do not delay already available sources.

The simulator build also needed its existing framework-thinning script to strip FinderInfo/ResourceFork metadata from generated framework copies. This does not modify source frameworks or remove quarantine metadata.

## Validation

Passed on the tvOS 27 simulator with Xcode 27.1: **52 tests, 0 failures** across `StreamsDiscoveryTests` and `ActionStreamTests`. Added regression cases cover focus-triggered pagination (including repeated boundary events) and background-worker filter/sort output for 200 streams.

Physical Apple TV checks remain necessary: open Play with several configured add-ons, move immediately while results arrive, reach later pages, change provider and sort, refresh during/after loading, retry an empty result, then dismiss/reopen and confirm Infuse handoff. Measure interaction/frame latency before claiming a quantified performance improvement. No account credentials or source URLs are included in this document.
