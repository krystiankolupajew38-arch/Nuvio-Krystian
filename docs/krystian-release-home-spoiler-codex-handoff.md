# Nuvio-K — Codex source-review handover

Branch: `fix/upcoming-episode-air-dates` (do not merge into `main`).
Baseline: `bf6d54bca5ee81b69e9c32b889fd8e75836fe654` (validated build 77).
Prior plan: `docs/krystian-air-dates-home-spoilers-plan.md`.

## Changes

- `CatalogRepository`: configured, enabled metadata add-ons are considered in user priority order, including across type fallbacks. Requests execute concurrently but an earlier still-pending provider prevents a later completed provider from winning. Built-in Cinemeta is a separate, enabled-only fallback. Metadata cache context now includes ordered add-on preferences/profile and TMDB language.
- `EpisodeReleasePolicy`: strict classification as exact timezone-aware instant, device-local timestamp without timezone, date-only calendar statement, or invalid. Exact instants use device timezone with DST; a date-only provider value retains its day. Valid, more precise originals beat TMDB's date-only `air_date`; invalid values fall back to valid metadata. `ContinueWatchingBuilder`, `ContinueWatchingItem`, refresh of missing episode metadata and `NuvioDateDisplay` use the shared precedence/day logic.
- TMDB locale: manual English `en`, English (United States) `en-US`, and English (United Kingdom) `en-GB` are distinct. Automatic keeps the device's regional English tag while preserving legacy behavior for other app languages. Saved manual tag persists/syncs; metadata cache context varies with resolved TMDB language.
- Home: returning from another tab does not, by itself, re-fetch progress once initialized or recreate catalog task identity. Remote progress changes still refresh immediately; stored rows are unchanged on provider failure. A lightweight no-network periodic eligibility pass detects date/time boundary transitions. Existing focus/scroll retention, explicit refresh, profile changes and configured catalog TTL remain.
- Blur: opt-in profile setting in Layout → Details Page, default off. Details and Home/Upcoming only blur actual episode artwork for unwatched episodes. Episode text, gradient, badges, progress and focus outlines remain sharp; fallback series artwork stays unblurred. The pure `EpisodeSpoilerPolicy` decision can be unit tested.
- Advanced → Release Date Diagnostics: device-local opt-in. Prints selected configured provider position, episode season/number, date precision, resolved local day and selection rationale. No manifest URLs, stream URLs, tokens, IP addresses or account identifiers. No extra network fetches.

## Validation already performed

- Inspected upstream Nuvio Mobile `cmp-rewrite` and Desktop `Dev` metadata resolution and spoiler styling; PR #2032 explains removal of date-only TMDB release enrichment.
- Reviewed branch contents and change scope through GitHub, checked expected source invariants and performed a standalone Foundation timezone conversion smoke check (London, New York, Los Angeles, Sydney).
- Added regression tests: `KrystianReleaseAndSpoilerTests`, `KrystianReleaseMetadataRegressionTests`, `TmdbMetadataLanguageTests`.
- No Xcode/tvOS build, simulator suite, signing, device install or deployment was performed.

## Codex assignment

1. Independently review the **combined** branch diff against the baseline and verify that unrelated Infuse/Trakt, Stream Picker, Watch Party #304–307 and Nuvio-K bundle/branding changes are unchanged.
2. Compile for the intended tvOS target and run tests, correcting any Swift compile/runtime issues. Pay special attention to `EpisodeReleasePolicy` parsing and DST ambiguity, SwiftUI `@AppStorage` profile isolation, Home `task(id:)`/focus lifecycle, add-on request concurrency/cancellation, and visible blur/clipping around a focused landscape card.
3. In tests/simulator or controlled development fixtures, verify exact timestamp examples (2026-10-21 20:30 EDT → 2026-10-22 London; 2026-10-20 21:00 EDT → 2026-10-21 London), date-only fallback, disabled built-in/custom Cinemeta ordering, en-GB TMDB request parameter/persistence, Home → Library → Home zero incidental fetches, immediate callback progress refresh, release-time rollover and blur watched/unwatched behavior.
4. Check release-cache invalidation when metadata source, profile and TMDB locale change. Check selected progress provider watched status across Trakt/Nuvio Sync, and check that an artwork load failure does not inadvertently reveal spoiler thumbnails.
5. Make any necessary fixes **only on this branch**, document actual test results and prepare a future signed build if feasible. **Do not install or deploy to Apple TV**, do not alter build 77 or installed configuration, do not merge into main or work on the Infuse progress branch.

## Known limits

- A provider returning only a calendar date cannot establish the true original broadcast hour. Do not infer one from title/region; use date-only fallback.
- Device-specific SwiftUI focus restoration, blur performance, app identity/signing, and real provider timing require Codex simulator or controlled device validation.
- Current diagnostics identify configured metadata providers by ordinal priority to avoid exposing configurable private endpoints.
- Infuse/Trakt follow-up is intentionally not implemented until the user reports remaining build 77 behavior.
