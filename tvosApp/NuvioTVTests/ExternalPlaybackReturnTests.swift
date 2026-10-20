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
        for query in ["", "position=NaN", "position=-1", "position=9", "position=3000", "progress=oops"] {
            let callback = ExternalPlaybackCallback.parse(URL(string: "nuvio-krystian://external-playback/return-test?\(query)")!)!
            XCTAssertNil(session.sample(for: callback), query)
        }
        var unknown = session
        unknown = ExternalPlaybackSession(id: session.id, meta: session.meta, sourceURL: session.sourceURL,
                                          season: 1, episode: 3, duration: nil, profileID: session.profileID)
        XCTAssertNil(unknown.sample(for: ExternalPlaybackCallback(id: session.id, isError: false, progress: 1, position: nil)))
        XCTAssertEqual(unknown.sample(for: ExternalPlaybackCallback(id: session.id, isError: false, progress: nil, position: 900, duration: 2000))?.position, 900)
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
        XCTAssertEqual(ExternalPlaybackSessionStore.load(defaults: defaults), session)
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
            XCTAssertEqual(duration, 2_000)
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
        XCTAssertNil(unknown.sample(for: callback))
        let underestimated = ExternalPlaybackSession(
            id: original.id, meta: original.meta, sourceURL: original.sourceURL,
            season: original.season, episode: original.episode, duration: 200,
            profileID: original.profileID
        )
        XCTAssertNil(underestimated.sample(for: callback))
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
}
