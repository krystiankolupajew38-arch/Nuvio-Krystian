import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class KrystianReleaseAndSpoilerTests: XCTestCase {
    private let newYorkRelease = "2026-10-21T20:30:00-04:00"

    func testUSEveningBroadcastCrossesUKDateDuringBritishSummerTime() {
        XCTAssertEqual(
            EpisodeReleasePolicy.localReleaseDay(newYorkRelease, timeZone: TimeZone(identifier: "Europe/London")!),
            "2026-10-22"
        )
        XCTAssertEqual(
            EpisodeReleasePolicy.localReleaseDay("2026-10-20T21:00:00-04:00", timeZone: TimeZone(identifier: "Europe/London")!),
            "2026-10-21"
        )
    }

    func testWorldwideZonesConvertTheSameInstantWithoutHardcodedProgrammeExceptions() {
        let cases = [
            ("Europe/London", "2026-10-22"),
            ("America/New_York", "2026-10-21"),
            ("America/Los_Angeles", "2026-10-21"),
            ("Australia/Sydney", "2026-10-22"),
            ("Pacific/Auckland", "2026-10-22"),
            ("UTC", "2026-10-22")
        ]
        for (identifier, expected) in cases {
            let zone = TimeZone(identifier: identifier)!
            XCTAssertEqual(
                EpisodeReleasePolicy.localReleaseDay(newYorkRelease, timeZone: zone),
                expected, "Unexpected date in \(identifier)"
            )
        }
    }

    func testUKDSTTransitionsUseRealOffsetForExactInstants() {
        let london = TimeZone(identifier: "Europe/London")!
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-03-29T00:30:00Z", timeZone: london), "2026-03-29")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-03-29T01:30:00Z", timeZone: london), "2026-03-29")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-25T00:30:00Z", timeZone: london), "2026-10-25")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-25T01:30:00Z", timeZone: london), "2026-10-25")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-24T23:30:00Z", timeZone: london), "2026-10-25")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-25T23:30:00Z", timeZone: london), "2026-10-25")
    }

    func testDateOnlyAndUnzonedTimestampsDoNotInventUSBroadcastTimes() {
        let london = TimeZone(identifier: "Europe/London")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        for zone in [london, losAngeles] {
            XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-21", timeZone: zone), "2026-10-21")
            XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-21T20:30:00", timeZone: zone), "2026-10-21")
        }
        XCTAssertEqual(EpisodeReleasePolicy.precision(of: "2026-10-21"), .dateOnly)
        XCTAssertEqual(EpisodeReleasePolicy.precision(of: newYorkRelease), .exact)
        XCTAssertEqual(EpisodeReleasePolicy.precision(of: "2026-10-21T20:30:00"), .localTime)
        XCTAssertEqual(
            EpisodeReleasePolicy.precision(of: "2026-03-29T01:30:00", timeZone: london),
            .invalid, "The nonexistent UK DST local hour must be rejected"
        )
    }

    func testInvalidDatesAreNeverReinterpretedAsValidCalendarDays() {
        for invalid in ["2026-02-30", "2026-13-01", "2026-10-99",
                        "2026-10-21T30:00:00Z", "today", "", "2026-10-21THI"] {
            XCTAssertEqual(EpisodeReleasePolicy.precision(of: invalid), .invalid)
            XCTAssertNil(EpisodeReleasePolicy.localReleaseDay(invalid))
        }
    }

    func testExactAddonTimestampWinsOverTMDBDateOnlyAndInvalidAddonFallsBack() {
        XCTAssertEqual(
            EpisodeReleasePolicy.preferredRelease(primary: newYorkRelease, fallback: "2026-10-21"),
            newYorkRelease
        )
        XCTAssertEqual(
            EpisodeReleasePolicy.preferredRelease(primary: "invalid", fallback: "2026-10-21"),
            "2026-10-21"
        )
        XCTAssertEqual(
            EpisodeReleasePolicy.preferredRelease(primary: "2026-10-21", fallback: newYorkRelease),
            newYorkRelease
        )
        XCTAssertEqual(
            EpisodeReleasePolicy.preferredRelease(primary: "2026-10-21", fallback: "2026-10-20"),
            "2026-10-21"
        )
    }

    func testContinueWatchingUsesSameResolvedDateAsEpisodeGuide() {
        let video = NuvioVideo(
            id: "tt1234000:6:3", title: "Episode 3", season: 6, episode: 3,
            released: newYorkRelease
        )
        let meta = NuvioMeta(id: "tt1234000", name: "Fixture", type: "series", videos: [video])
        let item = ContinueWatchingItem(
            meta: meta, streamUrl: "", position: 1, duration: 2_000,
            lastWatchedAt: Date(timeIntervalSince1970: 1),
            season: 6, episode: 3, released: "2026-10-21", isUpNext: true
        )
        XCTAssertEqual(item.effectiveEpisodeReleaseDate, newYorkRelease)
        XCTAssertEqual(
            EpisodeReleasePolicy.localReleaseDay(item.effectiveEpisodeReleaseDate, timeZone: TimeZone(identifier: "Europe/London")!),
            "2026-10-22"
        )
    }

    func testMetadataSelectionWaitsForPendingHigherPrioritySuccess() {
        XCTAssertNil(OrderedMetadataSelection.winningIndex(successful: [2], pending: [0, 1]))
        XCTAssertNil(OrderedMetadataSelection.winningIndex(successful: [1, 2], pending: [0]))
        XCTAssertEqual(OrderedMetadataSelection.winningIndex(successful: [1, 2], pending: [3]), 1)
        XCTAssertEqual(OrderedMetadataSelection.winningIndex(successful: [0, 2], pending: [1]), 0)
        XCTAssertNil(OrderedMetadataSelection.winningIndex(successful: [], pending: []))
    }

    func testBuiltInCinemetaStaysOffWhenOnlyCustomManifestEnabled() {
        let suite = "krystian-addon-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        // An enabled non-Cinemeta add-on means the built-in is not implicit.
        let custom = [StreamAddonPreference(
            url: "https://metadata.example.test/manifest.json", enabled: true
        )]
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(custom, in: store)
        XCTAssertFalse(CinemetaCatalogRepository.isCinemetaEnabled(in: store))
    }

    func testBlurOnlyEpisodeArtworkAndOnlyWhenUnwatched() {
        XCTAssertFalse(EpisodeSpoilerPolicy.shouldBlur(enabled: false, isWatched: false, hasEpisodeArtwork: true))
        XCTAssertTrue(EpisodeSpoilerPolicy.shouldBlur(enabled: true, isWatched: false, hasEpisodeArtwork: true))
        XCTAssertFalse(EpisodeSpoilerPolicy.shouldBlur(enabled: true, isWatched: true, hasEpisodeArtwork: true))
        XCTAssertFalse(EpisodeSpoilerPolicy.shouldBlur(enabled: true, isWatched: false, hasEpisodeArtwork: false))
        XCTAssertFalse(EpisodeSpoilerPolicy.shouldBlur(
            enabled: true, isWatched: false, hasEpisodeArtwork: true, displaysEpisodeArtwork: false
        ))
    }

    func testHomeTabSwitchDoesNotRequireProviderFetchAfterInitialization() {
        XCTAssertFalse(TVHomeTabRefreshPolicy.needsInitialProgressFetch(initialFinished: true, sourceChanged: false))
        XCTAssertTrue(TVHomeTabRefreshPolicy.needsInitialProgressFetch(initialFinished: false, sourceChanged: false))
        XCTAssertTrue(TVHomeTabRefreshPolicy.needsInitialProgressFetch(initialFinished: true, sourceChanged: true))
    }

    func testBlurSettingAndTMDBLanguageAreIncludedInProfileSync() {
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.blurUnwatchedEpisodes))
        XCTAssertFalse(SettingsKey.deviceLocal.contains(SettingsKey.blurUnwatchedEpisodes))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.tmdbLanguage))
        XCTAssertFalse(SettingsKey.deviceLocal.contains(SettingsKey.tmdbLanguage))
    }
}
