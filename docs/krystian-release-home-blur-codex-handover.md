# Nuvio-Krystian | Codex review handover (release dates, Home, TMDB, spoilers)

**Branch:** `fix/upcoming-episode-air-dates`
**Base:** validated build 77 source `bf6d54bca5ee81b69e9c32b889fd8e75836fe654`
**Previous plan:** `docs/krystian-air-dates-home-spoilers-plan.md`

The application source changes and focused regression fixtures are committed on this branch. **No Xcode/tvOS compilation, simulator tests, signing, package generation or Apple TV installation was performed during this source-only implementation stage.** Codex must independently review and validate the final branch HEAD, and fix any resulting defects on this branch before preparing a future signed build. Preserve build 77 and do not install anything without explicit approval.

## Implementation

### Metadata priority
`CinemetaCatalogRepository.loadMetadata` builds candidates from the **enabled, ordered manifest preferences** and supported resource/type/id combinations. The request list is sorted by configured manifest priority **first**, compatible fallback media type second. Requests run concurrently, but `OrderedMetadataSelection` only accepts a successful result after every higher-priority candidate has finished unsuccessfully. Consequently a faster lower-priority response cannot override the preferred source. Built-in Cinemeta is a fallback **only if its enabled setting permits it**. Successful full metadata is cached per profile/TMDB language/add-on preference identity; catalog-only metadata does not become authoritative full metadata. Jellyfin has its existing special-case priority; metadata and Home catalog sources are not conflated.

### Release selection and display
`EpisodeReleasePolicy` classifies ISO values as `exact` (Z or numeric timezone offset), `localTime` (a valid timestamp with no offset), `dateOnly` (valid YYYY-MM-DD) or `invalid`. Fully zoned timestamps are converted as true instants to the Apple TV's configured timezone for display and eligibility. Unzoned timestamps are interpreted in the device's local zone, and date-only values retain their original calendar day; no US broadcast hour or UK streaming-platform release schedule is fabricated. Invalid values do not gain inferred dates. The original add-on episode timestamp beats less precise TMDB `air_date`, while TMDB remains the valid fallback when better release values are unavailable. At equal precision the original value takes precedence. Episode titles, summaries, stills and other TMDB enrichment remain enabled.

`ContinueWatchingBuilder`, `ContinueWatchingItem.effectiveEpisodeReleaseDate`, `NuvioDateDisplay`, and episode-list release display use this shared policy. Precise release instants are used for aired/unreleased and drop-status comparisons. Calendar-only dates stay day-based.

**Acceptance data, not hardcoded title exceptions:** A US 2026-10-21 20:30 Eastern instant displays **2026-10-22 in London**, and a US 2026-10-20 21:00 Eastern instant displays **2026-10-21 in London**, provided a genuinely precise timestamp is supplied by the provider. Date-only data cannot establish those next-day outcomes.

### Home stability
Returning Home from Library/Settings no longer automatically starts a remote progress fetch solely because `isActive` changed. Loaded Continue Watching, Upcoming and catalog snapshots are retained, and existing focus restoration, row scroll state, and equal-content deduplication remain in place. Initial load, progress-source change, app foreground, explicit events (including Infuse/Trakt callback notifications), valid stale-data refresh and profile changes still allow necessary updates. Release eligibility is reevaluated locally on a bounded timer without networking. Remote-provider fetch errors do not intentionally clear good visible results.

### TMDB language
`English` (`en`), `English (United States)` (`en-US`) and `English (United Kingdom)` (`en-GB`) are separate manual TMDB choices, not new whole-app languages. Automatic preference respects the chosen app UI language, with regional English retained from the device when app UI uses System. Saved TMDB strings are kept as normal synced language tags. Language and add-on preference changes invalidate relevant metadata caches without a navigation-only refetch.

### Spoiler protection
`Blur Unwatched Episodes`, under Home Layout / Details Page settings, defaults **Off** and is in the profile settings/sync key set. The official Mobile approach is reproduced by a substantial **18-point** SwiftUI artwork-layer blur. Details episode cards and Continue Watching/Upcoming cards with genuine episode stills use `EpisodeSpoilerPolicy`; series artwork, text, progress, gradients, focus outlines and the player remain sharp. Watched/completed episode state resolves by episode identity, and partially watched/unknown state remains spoiler-protected.

### Privacy-safe diagnostics
Advanced Settings exposes device-local **Release Date Diagnostics**, default Off. Opt-in reports include the configured metadata provider priority index, episode numbers, release precision, resulting local date and selection reason; the repository's metadata stage and Continue Watching's enrichment stage are both represented. Avoid printing URLs, access tokens, stream paths, private account/device identifiers or unredacted provider logs. Rendering Home cards does not trigger new network diagnostics.

## Added/revised tests

- `KrystianReleaseAndSpoilerTests.swift` — UK summer/winter DST, US/Pacific/Australia/Auckland/UTC calendar conversion, invalid/date-only/unzoned values, add-on precedence, disabled built-in Cinemeta, spoiler decision, Home tab-fetch policy and settings-sync keys.
- `KrystianReleaseMetadataRegressionTests.swift` — independent release/date precedence, timezone and international cases, Home/guide consistency, concurrent metadata ordering, TMDB language variants and profile-isolated blur setting suites.
- `TmdbMetadataLanguageTests.swift` — regional UK/US English manual and automatic choices plus cache invalidation.

**Checks completed:** GitHub branch/parent/diff inspections and targeted source review; standalone Linux Foundation ISO8601 calendar checks on the two acceptance instants, UK DST and international zones (6/6). **Not run:** the app's XCTest suite, Xcode compilation, simulator navigation/focus, remote-provider integration, signing and deployment.

## Codex instructions

1. Confirm the remote HEAD of `fix/upcoming-episode-air-dates`; review **all commits since `06b7ef26a5b88072ac48337b415450414ba04a70`** and the final combined diff independently. Reconcile any newer commits rather than rewriting them.
2. Compile the tvOS target and run unit + simulator tests; inspect any strict-concurrency, SwiftUI type-checking, `onChange` and actor-isolation diagnostics. Repair issues on this same development branch and add regression tests rather than weakening checks.
3. Specifically test configured custom Cinemeta en-GB with built-in Cinemeta disabled; mixed manifest completion order; data freshness after profile/add-on/language changes; exact timestamp vs TMDB date-only; UK DST; invalid/unzoned values; details/list/Home date agreement.
4. Test Home → Library → Home on device/simulator, including focus, row scroll, no extraneous requests, remote provider errors, foreground stale refresh, release-time boundary, profile switching and **immediate external Infuse progress callbacks**.
5. Exercise blur Off/On, completed, partial and unknown watch state, episode-specific still vs generic series backdrop, both Home orientations, missing thumbnail, focus transitions, and multiple profiles. Verify that settings and Nuvio Sync round-trip `en-GB` and the blur key.
6. Recheck build 77's Infuse callback/reconciliation, percentage resume, explicit restart, no duplicate Trakt reporting, profile/episode isolation, stream picker, Watch Party PRs #304–307, exclusion of #308, and Nuvio-K identity.
7. After tests pass, prepare a future signed build **without installing or deploying it**. Do not modify the current build 77, main or `fix/infuse-return-progress-reliability`, and never commit secrets, signing assets, profiles, stream URLs or generated app packages.

## Remaining considerations

- Upstream metadata with only a date cannot supply the exact original US broadcast hour; users will correctly see the date-only fallback, not an invented one-day shift.
- Apple TV focus, 18-point blur performance, fetched provider error cases, and Nuvio Sync round-trips need real tvOS validation.
- Some legacy code retains date-only UTC-midnight sort keys internally while avoiding that midnight for local displayed calendar dates; test boundary behavior carefully.
- Validate that provider-specific watched history has propagated before unblurring, especially immediately after changing the selected progress provider.
- Investigate any still-failing Infuse/Trakt behavior **after** this branch is validated and after collecting exact reproduction steps from the user. Do not alter Infuse code in this change set.
