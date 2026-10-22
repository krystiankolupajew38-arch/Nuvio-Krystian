import Foundation
import XCTest
@testable import NuvioTV

/// Pure policies only: no network calls, device pairing or third-party credentials.
@MainActor
final class KrystianReleaseMetadataRegressionTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!
    private let eastern = TimeZone(identifier: "America/New_York")!
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    func testOriginalUSHistoricalReleaseInstantsConvertToUKDates() {
        // Abbott Elementary S6E3, 20:30 US Eastern, October 21, 2026.
        let abbott = "2026-10-21T20:30:00-04:00"
        XCTAssertEqual(EpisodeReleasePolicy.precision(of: abbott), .exact)
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay(abbott, timeZone: london), "2026-10-22")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay(abbott, timeZone: eastern), "2026-10-21")

        // VisionQuest, 21:00 US Eastern, October 20, 2026.
        let visionQuest = "2026-10-20T21:00:00-04:00"
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay(visionQuest, timeZone: london), "2026-10-21")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay(visionQuest, timeZone: pacific), "2026-10-20")
    }

    func testBritishDSTTransitionsRetainRealInstants() {
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-03-29T00:30:00Z", timeZone: london), "2026-03-29")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-03-29T23:30:00Z", timeZone: london), "2026-03-30")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-25T00:30:00Z", timeZone: london), "2026-10-25")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-25T01:30:00Z", timeZone: london), "2026-10-25")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-25T23:30:00Z", timeZone: london), "2026-10-25")
    }

    func testAdditionalInternationalTimezones() {
        let utc = "2026-10-21T00:30:00Z"
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay(utc, timeZone: pacific), "2026-10-20")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay(utc, timeZone: tokyo), "2026-10-21")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-21T17:00:00Z", timeZone: sydney), "2026-10-22")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay(utc, timeZone: TimeZone(secondsFromGMT: 0)!), "2026-10-21")
    }

    func testDateOnlyAndLocalTimestampDoNotAssumeUSBroadcastTime() {
        XCTAssertEqual(EpisodeReleasePolicy.precision(of: "2026-10-21"), .dateOnly)
        XCTAssertEqual(EpisodeReleasePolicy.precision(of: "2026-10-21T20:30:00"), .localTime)
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-21", timeZone: london), "2026-10-21")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-21", timeZone: tokyo), "2026-10-21")
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay("2026-10-21T20:30:00", timeZone: london), "2026-10-21")
    }

    func testInvalidDatesDoNotSurfaceAsAuthoritative() {
        for invalid in ["2026-02-30", "2026-13-01", "2026-10-21T99:00:00Z", "garbage", "", "2026-10-21T25:00", "2026-10-21T12:60:00Z", "2026-10-21T12:00:60Z", "2026-10-21T12:00:00+24:00", "2026-10-21T12:00:00+01:60"] {
            XCTAssertEqual(EpisodeReleasePolicy.precision(of: invalid), .invalid, "Unexpected valid release: \(invalid)")
            XCTAssertNil(EpisodeReleasePolicy.localReleaseDay(invalid))
            XCTAssertNil(EpisodeReleasePolicy.preferredRelease(primary: invalid, fallback: nil))
        }
    }

    func testAddonExactTakesPrecedenceOverTMDBDateOnly() {
        let timestamp = "2026-10-21T20:30:00-04:00"
        XCTAssertEqual(EpisodeReleasePolicy.preferredRelease(primary: timestamp, fallback: "2026-10-21"), timestamp)
        XCTAssertEqual(EpisodeReleasePolicy.preferredRelease(primary: "2026-10-21", fallback: timestamp), timestamp)
        XCTAssertEqual(EpisodeReleasePolicy.preferredRelease(primary: nil, fallback: "2026-10-21"), "2026-10-21")
        XCTAssertEqual(EpisodeReleasePolicy.preferredRelease(primary: "2026-10-21", fallback: "2026-10-20"), "2026-10-21")
        XCTAssertEqual(EpisodeReleasePolicy.preferredRelease(primary: "invalid", fallback: "2026-10-21"), "2026-10-21")
    }

    func testContinueWatchingAndEpisodeGuideResolveSameRelease() {
        let exact = "2026-10-21T20:30:00-04:00"
        let video = NuvioVideo(id: "tt1234567:6:3", title: "Episode 3", season: 6, episode: 3, released: exact)
        let meta = NuvioMeta(id: "tt1234567", name: "Sample", type: "series", videos: [video])
        let item = ContinueWatchingItem(
            meta: meta, streamUrl: "", position: 1, duration: 2_400,
            lastWatchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            season: 6, episode: 3, released: "2026-10-21", isUpNext: true
        )
        XCTAssertEqual(item.effectiveEpisodeReleaseDate, exact)
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay(item.effectiveEpisodeReleaseDate, timeZone: london),
                       EpisodeReleasePolicy.localReleaseDay(video.released, timeZone: london))
    }

    func testMetadataProviderCompletionOrderCannotDetermineWinner() {
        XCTAssertNil(OrderedMetadataSelection.winningIndex(successful: [2], pending: [0, 1]))
        XCTAssertNil(OrderedMetadataSelection.winningIndex(successful: [1, 2], pending: [0]))
        XCTAssertEqual(OrderedMetadataSelection.winningIndex(successful: [1, 2], pending: []), 1)
        XCTAssertEqual(OrderedMetadataSelection.winningIndex(successful: [2], pending: [3]), 2)
        XCTAssertEqual(OrderedMetadataSelection.winningIndex(successful: [0, 2], pending: [1]), 0)
    }

    func testManualTMDBLanguagesAreDistinctAndPersistent() {
        let name = "krystian-tmdb-regression-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        for tag in ["en", "en-US", "en-GB"] {
            TmdbMetadataLanguage.selectManual(tag, in: store)
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store), tag)
            XCTAssertEqual(store.string(forKey: SettingsKey.tmdbLanguage), tag)
            XCTAssertFalse(TmdbMetadataLanguage.followsApp(in: store))
        }
        store.set("", forKey: SettingsKey.language)
        TmdbMetadataLanguage.selectAutomatic(in: store)
        XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store, systemLanguage: "en-GB"), "en-GB")
        XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store, systemLanguage: "en-US"), "en-US")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.tmdbLanguage))
    }

    func testBlurSettingIsProfileScopedAndDefaultsOff() {
        let key = SettingsKey.blurUnwatchedEpisodes
        let suiteA = "krystian-blur-a-\(UUID().uuidString)"
        let suiteB = "krystian-blur-b-\(UUID().uuidString)"
        let a = UserDefaults(suiteName: suiteA)!
        let b = UserDefaults(suiteName: suiteB)!
        defer {
            a.removePersistentDomain(forName: suiteA)
            b.removePersistentDomain(forName: suiteB)
        }
        XCTAssertFalse(a.bool(forKey: key))
        XCTAssertFalse(b.bool(forKey: key))
        a.set(true, forKey: key)
        XCTAssertTrue(a.bool(forKey: key))
        XCTAssertFalse(b.bool(forKey: key))
        XCTAssertTrue(SettingsKey.all.contains(key))
    }
    func testAbbottEligibilityAtExactLondonBoundary() {
        let abbott = "2026-10-21T20:30:00-04:00"
        let dateFormatter = ISO8601DateFormatter()
        func time(_ utc: String) -> Date { dateFormatter.date(from: utc)! }
        let london = TimeZone(identifier: "Europe/London")!
        XCTAssertEqual(EpisodeReleasePolicy.localReleaseDay(abbott, timeZone: london), "2026-10-22")
        XCTAssertEqual(EpisodeReleasePolicy.releaseState(abbott, now: time("2026-10-21T22:00:00Z"), timeZone: london), .upcoming)
        XCTAssertEqual(EpisodeReleasePolicy.releaseState(abbott, now: time("2026-10-22T00:29:00Z"), timeZone: london), .airingToday)
        XCTAssertEqual(EpisodeReleasePolicy.releaseState(abbott, now: time("2026-10-22T00:30:00Z"), timeZone: london), .aired)
        XCTAssertFalse(EpisodeReleasePolicy.isNewEpisodeDrop(released: abbott, seedWatchedAt: time("2026-10-21T00:00:00Z"), now: time("2026-10-22T00:29:00Z")))
        XCTAssertTrue(EpisodeReleasePolicy.isNewEpisodeDrop(released: abbott, seedWatchedAt: time("2026-10-21T00:00:00Z"), now: time("2026-10-22T00:30:00Z")))
    }

    func testTMDBEnrichmentDoesNotReplacePreciseAddonRelease() {
        let original = NuvioVideo(id: "tt001:6:3", title: "Tryouts", season: 6, episode: 3, released: "2026-10-21T20:30:00-04:00")
        let tmdb = NuvioVideo(id: "tmdb:1:6:3", title: "Tryouts", season: 6, episode: 3, released: "2026-10-21")
        let merged = DetailsViewModel.mergeEpisodes(existing: [original], fromTmdb: [tmdb], parentId: "tt001")
        XCTAssertEqual(merged?.first?.released, original.released)
        let bad = NuvioVideo(id: original.id, title: original.title, season: 6, episode: 3, released: "invalid")
        XCTAssertEqual(DetailsViewModel.mergeEpisodes(existing: [bad], fromTmdb: [tmdb], parentId: "tt001")?.first?.released, "2026-10-21")
    }

    func testCalendarOnlyNeverProvesPreciseNewEpisodeAndMidnightCanBeReal() {
        let clock = ISO8601DateFormatter()
        let now = clock.date(from: "2026-10-22T02:30:00Z")!
        let previous = clock.date(from: "2026-10-20T23:00:00Z")!
        XCTAssertFalse(EpisodeReleasePolicy.isRecentlyReleased("2026-10-21", within: 60, now: now))
        XCTAssertFalse(EpisodeReleasePolicy.isNewEpisodeDrop(released: "2026-10-21", seedWatchedAt: previous, now: now))
        XCTAssertFalse(EpisodeReleasePolicy.isNewEpisodeDrop(released: "2026-10-21T00:00:00", seedWatchedAt: previous, now: now))
        XCTAssertTrue(EpisodeReleasePolicy.isNewEpisodeDrop(released: "2026-10-21T00:00:00Z", seedWatchedAt: previous, now: now))
        XCTAssertEqual(EpisodeReleasePolicy.releaseState(nil, now: now), .unknown)
        XCTAssertEqual(EpisodeReleasePolicy.releaseState("invalid", now: now), .unknown)
    }

    func testDiagnosticsAreOptInBoundedAndSanitised() {
        let store = ReleaseDateDiagnosticStore(isEnabled: false)
        let ep = NuvioVideo(id: "tt1:6:3", title: "Tryouts", season: 6, episode: 3, released: "2026-10-21T20:30:00-04:00")
        store.record(showTitle: "Abbott Elementary", episode: ep, originalRelease: ep.released, tmdbRelease: "2026-10-21", provider: "Configured metadata", cacheStatus: "Unknown")
        XCTAssertTrue(store.snapshots.isEmpty)
        store.setEnabled(true)
        store.record(showTitle: "Abbott Elementary", episode: ep, originalRelease: ep.released, tmdbRelease: "2026-10-21", provider: "Configured metadata", cacheStatus: "Unknown")
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots[0].precision, "exact")
        XCTAssertEqual(store.snapshots[0].source, "Original add-on metadata")
        XCTAssertEqual(store.snapshots[0].ukDateTime, "22 October 2026 at 01:30 BST")
        for i in 1...5 {
            let other = NuvioVideo(id: "tt1:6:\(i+3)", title: "E\(i)", season: 6, episode: i+3, released: "2026-10-21")
            store.record(showTitle: "Abbott", episode: other, originalRelease: other.released, tmdbRelease: nil, provider: "Unknown", cacheStatus: "Unknown")
        }
        XCTAssertEqual(store.snapshots.count, 5)
        XCTAssertFalse(store.snapshots.contains(where: { $0.episodeNumber == 3 }))
        store.record(showTitle: "https://secret.invalid/?token=secret", episode: ep, originalRelease: "https://secret.invalid/?token=secret", tmdbRelease: nil, provider: "https://secret.invalid", cacheStatus: "token=secret")
        XCTAssertFalse(store.snapshots.map { "\($0.showTitle) \($0.originalRelease) \($0.provider) \($0.cacheStatus)" }.joined().contains("secret"))
        store.setEnabled(false)
        XCTAssertTrue(store.snapshots.isEmpty)
    }

}
