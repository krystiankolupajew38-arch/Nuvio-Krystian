# Nuvio-K final review — 21 October 2026

Branch: `fix/infuse-progress-ui-stream-picker-performance`.
Version prepared for validation: **3.4.5 (78)**.
No physical installation, launch, uninstall, reset or provisioning modification
was performed. The separate installer and legacy deploy script were not executed.

## Baseline and release dates

Started clean at remote `c638e91` after fetching origin. Git ancestry confirms
`1facfb5d66176c751fec220da8890c13dd288df2`, `5779daf`, `d5435e5`, `1402ac9`
and `e344a6f` are retained. No fixes were cherry-picked again.

`EpisodeReleasePolicy` in `Models/CatalogModels.swift` validates calendar fields,
hours, minutes, seconds and timezone offsets before parsing; exact instants use
the configured timezone, while date-only values retain their stated day.
`preferredRelease` preserves exact add-on timestamps over TMDB date-only values.
`effectiveEpisodeReleaseDate` and the shared formatting/release policies feed
Details, episode lists, Home, Continue Watching and Upcoming.
`OrderedMetadataSelection` preserves configured metadata-provider priority.
`TmdbMetadataLanguage` retains distinct en, en-US and en-GB selections and
persistence. Home remains mounted between tabs and `TVHomeTabRefreshPolicy`
avoids repeating initialized fetches. `EpisodeSpoilerPolicy` and the profile
setting keep unwatched episode blur opt-in.

Registered regression suites are `KrystianReleaseAndSpoilerTests`,
`KrystianReleaseMetadataRegressionTests`, `TmdbMetadataLanguageTests`, and
`HomeStartupGateTests`. They cover UK midnight, both DST transitions, nonexistent
local times, exact/date-only precedence, provider ordering, language persistence
and spoiler defaults. This review adds invalid minute, second and offset cases.
Actual rendered focus/scroll behavior still requires device acceptance.

## Infuse and Trakt

- Rejected unverified historical ledger duration for Infuse again: those records
  have no measured-versus-estimated provenance. A player-supplied valid duration
  can drive the bar; generic movie/episode runtime cannot prove completion.
- Retained exact external checkpoints even at the completion threshold while
  Trakt completion is unresolved. Previously the callback handler avoided a
  duplicate completion but the checkpoint writer silently discarded its seconds.
- Retained the handoff start time in the durable checkpoint. Matching watched
  history during that handoff wins even when it predates callback receipt;
  history before a new handoff does not suppress a legitimate rewatch.
- Removed runtime-based reconstruction of provider percentages as exact seconds.
  Corrected Trakt percent parsing: 0.5 and 1 mean 0.5% and 1%, not 50% and 100%.
- Preserved the branch's exact callback authority over in-session scrobbles,
  session/URL/profile/account validation, retry journal, immediate notifications,
  episode-specific cleanup and suppression of duplicate Infuse Trakt reports.
- Added a bound before converting resume seconds to an integer URL argument,
  preventing a trap on an unrepresentably large finite value.

A matching provider percentage within the existing -300/+30-second window may
supply display progress while exact seconds remain the resume authority. A
provider timestamp over 30 seconds newer can represent later cross-device
playback, including a rewind. These are timestamp heuristics, not proof of a
shared playback session. Percentage display may await a provider fetch after
relaunch; exact seconds persist. If no trustworthy duration or percentage exists,
Resume is the appropriate presentation. No authentication flow was changed.

Firecore's [documented callback](https://support.firecore.com/hc/en-us/articles/215090997-API-for-Third-Party-Apps-Services)
returns lastPlayedUrl and position in seconds when playback closes; duration is
not promised. [Trakt playback documentation](https://trakt.docs.apiary.io/#reference/sync/get-playback-progress)
defines progress as a percentage. Library progress in other clients is not
assumed to have Trakt's semantics. Existing upstream comparisons are recorded in
`stream-picker-performance.md`; no upstream playback implementation was copied.

## Stream picker

Preserved independent per-provider manifest/stream loading, progressive publication,
configured source order, bounded stream timeouts, background response decoding,
background list derivation, focus-triggered pagination and asynchronous subtitle
readiness. Cancellation and active request checks prevent superseded jobs from
publishing. Filtering/sort changes keep focused items materialized where present.

Added actor-owned in-flight manifest sharing between stream and subtitle discovery.
Previously simultaneous cold-cache consumers issued duplicate requests. Failures
are not cached, and cancelling one waiter does not cancel shared work. A regression
checks ten simultaneous consumers perform one fetch and a failed result is retried.

The list worker regression checks sorting and pagination at 50, 500 and 2,000
streams. Initial simulator observations were 4.21 ms, 34.81 ms and 256.44 ms
respectively, including actor dispatch. These are single-run software measurements,
not before/after benchmarks or device frame/input latency claims. Subtitle arrival
still causes one list revision; cached card presentations and stable IDs limit
rebuilds. Live provider latency, scrolling and Siri Remote focus remain unverified.

## Validation and preparation

The first simulator attempt executed no tests because cached Swift package metadata
referenced deleted DerivedData paths. Repaired only those private cache paths,
retaining a backup and verifying replacement frameworks existed. Cached binaries
were not treated as test evidence. No tests were disabled.

Affected simulator run: **195 passed, 0 failed, 0 skipped**.
First full run: **1,305 passed, 0 failed, 0 skipped**, before the final handoff-time
completion regression fix. Final current-source full run: **1,306 passed,
0 failed, 0 skipped**, with 10 warning diagnostics.
Build/installer helper tests: **42 passed**, with all device operations mocked.
Branch guard now requires the current branch; security/signing/deployment guards
remain intact. Test fixtures follow the declared application version.

Five inherited files remain excluded by `Project.swift`: `CatalogDecodingTests`,
`DetailsViewModelTests`, `PerformanceTests`, `RustSDKIntegrationTests`, and
`StreamQualityTagsTests`. No passing result is claimed for them. UI tests were
not run. Existing Swift concurrency, unused-value and AppIntents metadata warnings
are not treated as new successful Swift 6 validation.

The private deployment record says 3.4.5 (76), and the previously prepared artifact
was build 77. A fresh read-only device inventory attempt was unavailable; the actual
installed build and signing continuity remain unconfirmed. Build 78 distinguishes
this candidate from both local records. Recheck inventory after explicit GO before
any update; do not infer data retention from signing verification alone.

## Final signed artifact

Clean generic tvOS preparation succeeded for **3.4.5 (78)**, with two build
warning diagnostics. `verify --json` passed: strict signatures, expected team,
certificate validity and authorization, provisioning, bundle identities, App Group,
callback scheme, source mapping and artifact hashes. An additional ZIP CRC and
SHA-256 comparison confirmed all 157 IPA files match the verified signed bundle.

Preserved app `com.krystian.nuvio`, extension `com.krystian.nuvio.TopShelf`, group
`group.com.krystian.nuvio`, `nuvio-krystian://`, branding and existing data formats.
The optional checkpoint field decodes absent in older records.

Embedded expiry dates (UTC and UK local time on 26 October):

- Top Shelf: **26 October 2026, 23:56:28**.
- App: **26 October 2026, 23:57:05**.

No profile renewal is inferred. The prepared IPA, private manifest, signing
material, result bundles and raw logs remain outside Git in restricted private
storage. The final documentation-only commit reuses the same application/test
fingerprints; preparation reuse re-verifies and maps the artifact to that commit.

Ready for review, not deployed. Before any physical update, require explicit
human GO and a successful fresh inventory/version check. After authorized
installation, validate real Infuse return timing, exact resume, watched/Next Up,
retained profiles/accounts, provider synchronization and Siri Remote focus.
