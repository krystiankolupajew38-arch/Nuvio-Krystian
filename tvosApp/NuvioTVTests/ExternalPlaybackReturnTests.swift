import XCTest
@testable import NuvioTV

final class ExternalPlaybackReturnTests: XCTestCase {
    private func externalFixture() -> ExternalPlaybackSession {
        ExternalPlaybackSession(
            id: "return-test", meta: NuvioMeta(id: "external-fixture", name: "Fixture", type: "series"),
            sourceURL: "https://example.invalid/episode", season: 1, episode: 3,
            duration: 2_000, profileID: "external-test-profile"
        )
    }

    func testExternalReturnUsesDocumentedPositionAndCompletionThreshold() {
        let session = externalFixture()
        for fraction in [1.0, 0.95, 0.45] {
            let callback = ExternalPlaybackCallback.parse(URL(string: "nuvio-krystian://external-playback/return-test?position=\(fraction * 2000)")!)!
            let sample = session.sample(for: callback)!
            XCTAssertEqual(sample.position / sample.duration, fraction)
            XCTAssertEqual(sample.position / sample.duration >= WatchProgressLedger.completionFraction, fraction >= 0.9)
        }
    }

    func testExternalReturnRejectsMissingMalformedAndUntrackableData() {
        let session = externalFixture()
        for query in ["", "position=NaN", "position=-1", "position=9", "progress=oops"] {
            let callback = ExternalPlaybackCallback.parse(URL(string: "nuvio-krystian://external-playback/return-test?\(query)")!)!
            XCTAssertNil(session.sample(for: callback), query)
        }
        var unknown = session
        unknown = ExternalPlaybackSession(id: session.id, meta: session.meta, sourceURL: session.sourceURL,
                                          season: 1, episode: 3, duration: nil, profileID: session.profileID)
        XCTAssertNil(unknown.sample(for: ExternalPlaybackCallback(id: session.id, isError: false, progress: 1, position: nil)))
        XCTAssertEqual(unknown.sample(for: ExternalPlaybackCallback(id: session.id, isError: false, progress: nil, position: 900))?.position, 900)
        XCTAssertEqual(unknown.sample(for: ExternalPlaybackCallback(id: session.id, isError: false, progress: nil, position: 900))?.duration, 0)
        XCTAssertEqual(session.sample(for: ExternalPlaybackCallback(id: session.id, isError: false, progress: nil, position: 3000))?.duration, 0)
    }

    @MainActor
    func testExternalReturnAcknowledgesOnlySuccessfulPersistence() {
        let suite = "external-return-transaction-test"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = externalFixture()
        ExternalPlaybackSessionStore.save(session, defaults: defaults)
        let callback = ExternalPlaybackCallback(id: session.id, isError: false, progress: 0.45, position: nil)
        var writes = 0
        XCTAssertFalse(ExternalPlaybackReturnHandler.handle(callback, profileID: session.profileID, defaults: defaults) { _, _, _ in
            writes += 1
            return false
        })
        var stagedSession = session
        stagedSession.returnedCallback = callback
        stagedSession.returnedAt = ExternalPlaybackSessionStore.load(defaults: defaults)?.returnedAt
        XCTAssertEqual(ExternalPlaybackSessionStore.load(defaults: defaults), stagedSession)
        XCTAssertTrue(ExternalPlaybackReturnHandler.handle(callback, profileID: session.profileID, defaults: defaults) { captured, position, duration in
            XCTAssertEqual(captured.season, 1)
            XCTAssertEqual(captured.episode, 3)
            XCTAssertEqual(captured.profileID, session.profileID)
            XCTAssertEqual(position, 900)
            XCTAssertEqual(duration, 2000)
            writes += 1
            return true
        })
        XCTAssertFalse(ExternalPlaybackReturnHandler.handle(callback, profileID: session.profileID, defaults: defaults) { _, _, _ in
            XCTFail("Duplicate callback persisted twice")
            return true
        })
        XCTAssertEqual(writes, 2)
    }

    @MainActor
    func testExternalReturnWrongProfileStaleAndInvalidCallbacksPreserveSession() {
        let suite = "external-return-guards-test"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = externalFixture()
        ExternalPlaybackSessionStore.save(session, defaults: defaults)
        for (id, profile, progress) in [(session.id, "other-profile", 0.95), ("old-session", session.profileID!, 0.95), (session.id, session.profileID!, 0.0)] {
            XCTAssertFalse(ExternalPlaybackReturnHandler.handle(
                ExternalPlaybackCallback(id: id, isError: false, progress: progress, position: nil),
                profileID: profile, defaults: defaults
            ) { _, _, _ in XCTFail("Invalid callback reached persistence"); return true })
            XCTAssertEqual(ExternalPlaybackSessionStore.load(defaults: defaults), session)
        }
    }

    @MainActor
    func testInfuseCallbackStagePersistsAcrossReloadAndValidatesPlayedURL() {
        let defaults = UserDefaults(suiteName: "infuse-stage-recovery-test")!
        defer { defaults.removePersistentDomain(forName: "infuse-stage-recovery-test") }
        var session = externalFixture()
        session.externalPlayerName = ExternalPlayer.infuse.rawValue
        ExternalPlaybackSessionStore.save(session, defaults: defaults)
        let good = ExternalPlaybackCallback(
            id: session.id, isError: false, progress: nil, position: 312,
            lastPlayedURL: session.sourceURL
        )
        let bad = ExternalPlaybackCallback(
            id: session.id, isError: false, progress: nil, position: 450,
            lastPlayedURL: "https://example.invalid/different-episode"
        )
        XCTAssertFalse(ExternalPlaybackSessionStore.stage(bad, defaults: defaults))
        XCTAssertTrue(ExternalPlaybackSessionStore.stage(good, defaults: defaults))
        XCTAssertEqual(ExternalPlaybackSessionStore.load(defaults: defaults)?.returnedCallback, good)
        XCTAssertFalse(ExternalPlaybackSessionStore.stage(bad, defaults: defaults))
        var writes = 0
        XCTAssertTrue(ExternalPlaybackReturnHandler.handle(
            good, profileID: session.profileID, defaults: defaults
        ) { captured, position, duration in
            XCTAssertEqual(captured.episode, session.episode)
            XCTAssertEqual(position, 312)
            XCTAssertEqual(duration, 0)
            writes += 1
            return true
        })
        XCTAssertEqual(writes, 1)
        XCTAssertNil(ExternalPlaybackSessionStore.load(defaults: defaults))
    }

    @MainActor
    func testFailedInfusePersistencePreservesPendingPosition() {
        let defaults = UserDefaults(suiteName: "infuse-stage-failure-test")!
        defer { defaults.removePersistentDomain(forName: "infuse-stage-failure-test") }
        var session = externalFixture()
        session.externalPlayerName = ExternalPlayer.infuse.rawValue
        ExternalPlaybackSessionStore.save(session, defaults: defaults)
        let result = ExternalPlaybackCallback(
            id: session.id, isError: false, progress: nil, position: 300,
            lastPlayedURL: session.sourceURL
        )
        XCTAssertFalse(ExternalPlaybackReturnHandler.handle(
            result, profileID: session.profileID, defaults: defaults
        ) { _, _, _ in false })
        XCTAssertEqual(ExternalPlaybackSessionStore.load(defaults: defaults)?.returnedCallback, result)
        XCTAssertFalse(ExternalPlaybackReturnHandler.recover(profileID: "another-profile", defaults: defaults))
        XCTAssertEqual(ExternalPlaybackSessionStore.load(defaults: defaults)?.returnedCallback, result)
    }

    func testUnverifiedEpisodeDurationNeverFabricatesCompletion() {
        let original = externalFixture()
        let unknown = ExternalPlaybackSession(
            id: original.id, meta: original.meta, sourceURL: original.sourceURL,
            season: original.season, episode: original.episode, duration: nil,
            profileID: original.profileID
        )
        let callback = ExternalPlaybackCallback(id: original.id, isError: false, progress: nil, position: 310)
        XCTAssertEqual(unknown.sample(for: callback)?.position, 310)
        XCTAssertEqual(unknown.sample(for: callback)?.duration, 0)
        let underestimated = ExternalPlaybackSession(
            id: original.id, meta: original.meta, sourceURL: original.sourceURL,
            season: original.season, episode: original.episode, duration: 200,
            profileID: original.profileID
        )
        XCTAssertEqual(underestimated.sample(for: callback)?.position, 310)
        XCTAssertEqual(underestimated.sample(for: callback)?.duration, 0)
    }

    @MainActor
    func testUnknownDurationCallbackPersistsExactSecondsWithoutCompletion() {
        let suite = "infuse-unknown-duration-test"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = externalFixture()
        let session = ExternalPlaybackSession(
            id: source.id, meta: source.meta, sourceURL: source.sourceURL,
            season: source.season, episode: source.episode, duration: nil,
            profileID: source.profileID, externalPlayerName: ExternalPlayer.infuse.rawValue
        )
        ExternalPlaybackSessionStore.save(session, defaults: defaults)
        let result = ExternalPlaybackCallback(
            id: session.id, isError: false, progress: nil,
            position: 1_420, lastPlayedURL: session.sourceURL
        )
        XCTAssertTrue(ExternalPlaybackReturnHandler.handle(
            result, profileID: session.profileID, defaults: defaults
        ) { _, position, duration in
            XCTAssertEqual(position, 1_420)
            XCTAssertEqual(duration, 0)
            XCTAssertFalse(duration > 0 && position / duration >= WatchProgressLedger.completionFraction)
            return true
        })
        XCTAssertNil(ExternalPlaybackSessionStore.load(defaults: defaults))
    }

    func testExplicitRemotePercentUsesRealStreamDurationForResume() {
        let item = ContinueWatchingItem(
            meta: NuvioMeta(id: "remote-percent-fixture", name: "Remote fixture", type: "series"),
            streamUrl: "", position: 0, duration: 0, lastWatchedAt: Date(),
            season: 1, episode: 2, explicitProgressPercent: 42
        )
        XCTAssertEqual(item.progress, 0.42, accuracy: 0.0001)
        XCTAssertEqual(item.resumePosition, 0)
        XCTAssertEqual(item.resumeProgressFraction ?? 0, 0.42, accuracy: 0.0001)
        // The loaded file duration, not show metadata, supplies the seek time.
        XCTAssertEqual(3_000 * (item.resumeProgressFraction ?? 0), 1_260, accuracy: 0.01)
        let exact = ContinueWatchingItem(
            meta: item.meta, streamUrl: "", position: 1_200, duration: 0,
            lastWatchedAt: Date(), season: 1, episode: 2
        )
        XCTAssertEqual(exact.resumePosition, 1_200)
        XCTAssertNil(exact.resumeProgressFraction)
    }

    @MainActor
    func testExternalErrorRetiresSessionWithoutWritingProgress() {
        let suite = "external-return-error-test"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = externalFixture()
        ExternalPlaybackSessionStore.save(session, defaults: defaults)
        XCTAssertFalse(ExternalPlaybackReturnHandler.handle(
            ExternalPlaybackCallback(id: session.id, isError: true, progress: 1, position: 2000),
            profileID: session.profileID, defaults: defaults
        ) { _, _, _ in XCTFail("Error callback persisted progress"); return true })
        XCTAssertNil(ExternalPlaybackSessionStore.load(defaults: defaults))
    }
    func testSourceURLNormalizationPreservesStreamIdentity() {
        XCTAssertTrue(ExternalPlaybackSessionStore.sameSourceURL(
            "https://EXAMPLE.invalid:443/media/%7efile?q=%41%2f", "https://example.invalid/media/~file?q=A%2F"))
        for different in ["https://example.invalid/media/other", "https://example.invalid/media/~file?q=A/",
                          "https://other.invalid/media/~file?q=A%2F", "http://example.invalid/media/~file?q=A%2F",
                          "https://example.invalid/media/~file?q=A%2F&token=other"] {
            XCTAssertFalse(ExternalPlaybackSessionStore.sameSourceURL("https://example.invalid/media/~file?q=A%2F", different))
        }
    }

    func testCallbackRejectsExtraPathComponents() {
        XCTAssertNil(ExternalPlaybackCallback.parse(URL(string: "nuvio-krystian://external-playback/id/other?position=20")!))
    }

    @MainActor
    func testNewHandoffCannotEraseUnprocessedReturn() {
        let suite = "external-pending-protection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = externalFixture()
        XCTAssertTrue(ExternalPlaybackSessionStore.save(session, defaults: defaults))
        let callback = ExternalPlaybackCallback(id: session.id, isError: false, progress: nil, position: 200)
        XCTAssertTrue(ExternalPlaybackSessionStore.stage(callback, defaults: defaults))
        let next = ExternalPlaybackSession(id: "new", meta: session.meta, sourceURL: session.sourceURL,
            season: 1, episode: 4, duration: nil, profileID: "different")
        XCTAssertFalse(ExternalPlaybackSessionStore.save(next, defaults: defaults))
        XCTAssertEqual(ExternalPlaybackSessionStore.load(defaults: defaults)?.returnedCallback, callback)
    }

    func testPercentageResumeMatchesEpisodeAndDoesNotOverrideExactSeconds() {
        let meta = externalFixture().meta
        let item = ContinueWatchingItem(meta: meta, streamUrl: "", position: 0, duration: 0,
            lastWatchedAt: Date(), season: 1, episode: 3, explicitProgressPercent: 42)
        XCTAssertEqual(item.resumeProgressFraction(season: 1, episode: 3), 0.42)
        XCTAssertNil(item.resumeProgressFraction(season: 1, episode: 4))
        XCTAssertNil(item.resumeProgressFraction(season: nil, episode: nil))
        let launch = ExternalPlayer.infuse.launchURL(for: URL(string: "https://example.invalid/video")!, position: item.resumePositionIfKnown)!
        XCTAssertFalse(URLComponents(url: launch, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "position" })
        let exact = ContinueWatchingItem(meta: meta, streamUrl: "", position: 700, duration: 0,
            lastWatchedAt: Date(), season: 1, episode: 3, explicitProgressPercent: 42)
        XCTAssertNil(exact.resumeProgressFraction)
        XCTAssertEqual(exact.resumePosition, 700)
    }

    @MainActor
    func testExactInfuseCheckpointSurvivesExpiryAndNewerRemoteRewindUsesPercentage() {
        let previous = ContinueWatchingStore.activeProfileId
        let profile = "external-checkpoint-\(UUID().uuidString)"
        ContinueWatchingStore.setActiveProfile(profile)
        let meta = externalFixture().meta
        defer {
            TraktProgressService.forgetLocalPlayback(meta: meta, notify: false)
            ContinueWatchingStore.setActiveProfile(previous)
        }
        let old = Date().addingTimeInterval(-7200)
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(meta: meta, position: 1400, duration: 0,
            season: 1, episode: 3, source: .trakt, notify: false, preservesExactPosition: true, recordedAt: old))
        TraktProgressService.reloadCheckpointsForTesting()
        XCTAssertEqual(TraktProgressService.currentContinueWatchingItem(for: meta, source: .trakt)?.position, 1400)
        XCTAssertNil(TraktProgressService.currentContinueWatchingItem(for: meta, source: .simkl))
        let stale = ContinueWatchingItem(meta: meta, streamUrl: "", position: 0, duration: 0,
            lastWatchedAt: old.addingTimeInterval(10), season: 1, episode: 3, explicitProgressPercent: 70)
        let merged = TraktProgressService.mergingLocalPlaybackCheckpoints(into: [stale], source: .trakt)
        XCTAssertEqual(merged.first?.position, 1400)
        XCTAssertEqual(merged.first?.duration, 0)
        let newer = ContinueWatchingItem(meta: meta, streamUrl: "", position: 0, duration: 0,
            lastWatchedAt: old.addingTimeInterval(300), season: 1, episode: 3, explicitProgressPercent: 20)
        let rewound = TraktProgressService.mergingLocalPlaybackCheckpoints(into: [newer], source: .trakt)
        XCTAssertEqual(rewound.first?.resumeProgressFraction, 0.2)
        XCTAssertEqual(rewound.first?.position, 0)
    }

    func testExplicitInfuseRestartOverridesNativeResume() {
        let url = ExternalPlayer.infuse.launchURL(for: URL(string: "https://example.invalid/episode")!, position: 0)!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "position" }?.value, "0")
    }

    func testInfuseSecondsDoNotCompleteAgainstUnverifiedHistoricalDuration() {
        var session = externalFixture()
        session.externalPlayerName = ExternalPlayer.infuse.rawValue
        let callback = ExternalPlaybackCallback(id: session.id, isError: false, progress: nil, position: 1950)
        XCTAssertEqual(session.sample(for: callback)?.duration, 0)
        var measured = callback
        measured.duration = 2000
        XCTAssertEqual(session.sample(for: measured)?.duration, 2000)
    }

    @MainActor
    func testOrdinaryCheckpointStillExpiresAndProfilesStayIsolated() {
        let previous = ContinueWatchingStore.activeProfileId
        let profile = "checkpoint-expiry-\(UUID().uuidString)"
        ContinueWatchingStore.setActiveProfile(profile)
        let meta = externalFixture().meta
        defer {
            ContinueWatchingStore.setActiveProfile(profile)
            TraktProgressService.forgetLocalPlayback(meta: meta, notify: false)
            ContinueWatchingStore.setActiveProfile(previous)
        }
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(meta: meta, position: 100, duration: 2000,
            season: 1, episode: 3, source: .trakt, notify: false, recordedAt: Date().addingTimeInterval(-7200)))
        XCTAssertTrue(TraktProgressService.mergingLocalPlaybackCheckpoints(into: [], source: .trakt).isEmpty)
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(meta: meta, position: 700, duration: 0,
            season: 1, episode: 3, source: .trakt, notify: false, preservesExactPosition: true))
        ContinueWatchingStore.setActiveProfile("different-\(profile)")
        XCTAssertTrue(TraktProgressService.mergingLocalPlaybackCheckpoints(into: [], source: .trakt).isEmpty)
        ContinueWatchingStore.setActiveProfile(profile)
        XCTAssertEqual(TraktProgressService.mergingLocalPlaybackCheckpoints(into: [], source: .trakt).first?.position, 700)
    }

    @MainActor
    func testInfuseCompletionDoesNotQueueTraktHistoryAndRetiresOlderCheckpoint() {
        let previous = ContinueWatchingStore.activeProfileId
        let previousWatched = WatchedStore.activeProfileId
        let profile = "infuse-completion-\(UUID().uuidString)"
        ContinueWatchingStore.setActiveProfile(profile)
        WatchedStore.setActiveProfile(profile)
        let meta = externalFixture().meta
        defer {
            TraktProgressService.forgetLocalPlayback(meta: meta, notify: false)
            WatchedStore.eraseProfile(profile)
            WatchedStore.setActiveProfile(previousWatched)
            ContinueWatchingStore.setActiveProfile(previous)
        }
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(meta: meta, position: 1400, duration: 0,
            season: 1, episode: 3, source: .trakt, notify: false, preservesExactPosition: true,
            recordedAt: Date().addingTimeInterval(-7200)))
        XCTAssertTrue(WatchedStore.recordPlaybackCompletion(meta, season: 1, episode: 3,
            completionID: "infuse-complete", source: .trakt, completionAccounts: [TraktWatchProgressSource.trakt.rawValue: "fixture-account"],
            externallyReportedProviders: [.trakt]))
        XCTAssertTrue(WatchedStore.pendingPlaybackCompletions(provider: .trakt, profileId: profile).isEmpty)
        XCTAssertTrue(TraktProgressService.mergingLocalPlaybackCheckpoints(into: [], source: .trakt).isEmpty)
    }

}
