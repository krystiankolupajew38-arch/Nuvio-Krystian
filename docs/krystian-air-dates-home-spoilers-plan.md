# Nuvio-K: episode dates, Home stability, spoiler blur, and Infuse follow-up

Planning status: investigation / no application behaviour modified.
Branch: `fix/upcoming-episode-air-dates`.
Base: `bf6d54bca5ee81b69e9c32b889fd8e75836fe654` (validated Nuvio-K 3.4.5 build 77).

## User-visible objectives

1. Display each episode's **original release instant in the Apple TV's configured timezone**, including daylight saving time, rather than displaying the US calendar date unconditionally. This is **not** a streaming-platform-specific regional release calendar. When no reliable release time is available, do not manufacture an hour or add a day.
2. Keep Continue Watching, Upcoming, Details, episode list, and their released/unreleased decisions consistent across navigation and refreshes.
3. Preserve Home rows, scroll/focus, and dates across Home -> Library/Settings -> Home without an unnecessary remote progress or metadata fetch.
4. Add an opt-in `Blur Unwatched Episodes` setting, following Nuvio Mobile's spoiler protection for episode thumbnails.
5. Investigate and subsequently fix any remaining Infuse playback/resume issues after obtaining precise real-device reproduction steps; do not regress the validated previous fixes.

## Source findings to address

- `tvosApp/NuvioTV/Sources/Core/Sync/ContinueWatchingBuilder.swift`: up-next and resume `released` use `tmdbEpisode?.released ?? next.released`, prioritising date-only TMDB `air_date` over any precise add-on timestamp.
- `tvosApp/NuvioTV/Sources/Models/CatalogModels.swift`: `ContinueWatchingItem.effectiveEpisodeReleaseDate` uses `episodeVideo?.released ?? released` and can reverse the enrichment precedence again; release-date display and air status are recomputed through multiple paths.
- `tvosApp/NuvioTV/Sources/Data/Repository/CatalogRepository.swift`: configured `meta` add-ons are requested concurrently; the first successfully completed result wins, not necessarily the configured source order. The built-in Cinemeta fallback is conditional on it being enabled.
- `tvosApp/NuvioTV/Sources/Core/TMDB/TmdbDetailsService.swift`: episode `air_date` is date-only; metadata localisation does not create a reliable time-of-day. `EpisodeMetadataEnrichment.fetch` is gated by TMDB Episodes, not by a standalone Release Dates option.
- `tvosApp/NuvioTV/Sources/Core/TMDB/TmdbMetadataLanguage.swift` supports BCP-47 values such as `en-GB`, but the TMDB settings picker uses `AppLanguage` with English represented as `en`. The UI should not silently rewrite a more specific synced value.
- `tvosApp/NuvioTV/Sources/NuvioTVApp.swift`: Home `onAppear` schedules a progress refresh; the `isActive` change handler also schedules a remote refresh on tab return. Requests can update row snapshots even with no real data changes. Existing notifications and explicit changes already provide more targeted invalidation pathways.
- Nuvio Mobile PR #2032 (merged 2026-09-22) removed TMDB Release Dates enrichment because its date-only outputs could override more precise metadata. Do **not** re-add that behaviour uncritically.
- Nuvio Mobile reference: `MetaScreenSettingsRepository.blurUnwatchedEpisodes` and its use in `DetailSeriesContent` and `HomeContinueWatchingSection`.

## Implementation plan

### A. Deterministic date resolution

1. Introduce a small shared release-date resolver (or equivalent focused abstraction) whose input retains the original value, source, and precision: `exact timestamp with zone`, `timestamp without zone`, `calendar day only`, `unknown`.
2. For timestamp-with-zone: compare against the true instant and display in `TimeZone.current`. For local timestamp without zone: preserve its calendar date and parse as a local time when appropriate. For date-only: preserve the stated calendar day, never assume a US 8 PM broadcast or shift it by +1 day.
3. Prioritise a trustworthy add-on **exact timestamp** over a TMDB `air_date`. TMDB date-only enrichment can provide a fallback only if there is no better release value. Continue using TMDB for translation, artwork, descriptions, etc.
4. Make multiple metadata add-on fetches deterministic: prefer the user-configured add-on order among successful responses (or an explicitly documented source-priority rule) regardless of network completion ordering.
5. Resolve once per episode/version of metadata and reuse the same result for Home, Upcoming, Details, episodes, sorting, `hasAired`, `isAiringToday`, and new-release badges. Ensure persisted snapshots retain the chosen source/precision where needed; avoid a stale guide value silently overruling it.
6. Create an opt-in privacy-safe diagnostic for target episodes which reports media ID/season/episode, provider **name**, raw release-date **string only**, whether timestamp is exact/date-only, derived local date, and final source choice. No addon manifest URLs, API keys, streaming URLs, IPs, account identifiers, or network logs.
7. If available add-ons and TMDB provide no exact instant, do not claim to know the true UK availability day. Report/use the date-only fallback and optionally evaluate a reliable public original-air-time provider in a separate scoped follow-up.

### B. Home stability without stale progress

1. Do not schedule a new remote Continue Watching/Upcoming fetch solely because Home's `isActive` flips on tab return. Avoid unconditional refresh-on-recreation after initial profile content is ready.
2. Keep Home's existing row snapshot, focus, scroll/viewport, and derived release dates while navigating between tabs; retain the same profile/provider identity.
3. Keep event-driven updates: Infuse callbacks, local progress saves, watched/unwatched, explicit refresh, provider/profile changes, and genuinely stale periodic background sync. Make fetch intervals bounded and independent of tab switching.
4. Refresh cached dates or change Upcoming->New Episode state when the **actual local calendar/release boundary** is crossed, not only on a tab change or app restart.
5. Apply new remote results atomically; no row clearing on transient network failures. Before invalidating presentation, detect whether the effective item ID, episode, watched/progress fields, ordering, or resolved release data truly changed.
6. Preserve profile isolation, selected progress-source changes, Home loading/startup gates, Infuse immediate checkpoints, and the ability to refresh while a Details/Player overlay is presented.

### C. Spoiler blur setting

1. Add profile-scoped `Blur Unwatched Episodes` in tvOS Settings near Details/Episode appearance options; default OFF to preserve existing behaviour.
2. Use existing episode-specific watched/completed logic, including selected watch-progress provider integration. A partially played but not completed episode should still be treated as unwatched for spoiler artwork.
3. Blur only episode-specific artwork in Details episode cards/list and optional Continue Watching/Upcoming episode thumbnails when displayed. Do not blur generic show posters or hero artwork, titles, focused outlines, or player video.
4. Apply blur to the image layer with a lightweight tvOS-friendly implementation; maintain focus/scroll performance and make the state update immediately after a watched change.
5. Follow official Nuvio Mobile as behavioural reference: `MetaScreenSettingsRepository`, `DetailSeriesContent`, `HomeContinueWatchingSection.shouldBlurContinueWatchingArtwork`.
6. Test setting OFF/ON, watched/partial/unwatched/unknown, multi-profile isolation, metadata fallback artwork, and navigation/performance.

### D. Infuse follow-up (pending real-device reproduction)

1. Ask for exact steps and what fails in the newly installed build 77: return callback, position in Home, reopen/resume, restart/relaunch, Trakt interference, episode isolation, or another failure.
2. Reproduce with privacy-safe local diagnostics (redact source URLs, tokens, Trakt auth, IPs, device identifiers).
3. Preserve existing `ExternalPlaybackReturnHandler` and Trakt reconciler safeguards; add focused regressions before proposing a correction.
4. Defer any new signing/build/install actions until separately approved; Codex may later compile/test and stage an app, but never install or merge without explicit permission.

## Test/acceptance matrix

- Abbott Elementary S6E3; VisionQuest ep 3/4; same data in both Home and Details.
- UK (including October DST shift), US Eastern/Pacific, Australia, UTC; release instants near midnight and DST transitions.
- Exact zoned timestamp vs date-only TMDB, conflict between two metadata providers, invalid timestamps, unknown times, and repeated fetches with different completion order.
- Home -> Library -> Home repeated without network refetch, full Home remount, focus/scroll preservation, background updates, explicit refresh, profile changes, offline/timeout behaviour.
- Watched, unwatched, and partially watched episode artwork; toggle and profile isolation.
- Infuse return progress continues to update immediately despite fewer Home automatic refreshes.

## Safety/validation

Preserve main and `fix/infuse-return-progress-reliability` unchanged. Use only this working branch. Do not compile, test, install, sign, or deploy from this planning document. Later use `scripts/krystian_build.py` and its privacy-safe reports to minimise Codex context cost. Never commit raw logs, secrets, device identifiers, private network data, or signing assets.
