import XCTest
@testable import NuvioTV

final class TraktContinueWatchingOwnershipTests: XCTestCase {
    private var profileA = ""
    private var profileB = ""
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousContinueWatchingProfileID: String?

    func testTraktSmallPercentagesAreNotFractions() {
        XCTAssertEqual(TraktProgressService.normalizedProgress(0.5), 0.5)
        XCTAssertEqual(TraktProgressService.normalizedProgress(1), 1)
        XCTAssertEqual(TraktProgressService.normalizedProgress(45), 45)
        XCTAssertNil(TraktProgressService.normalizedProgress(.nan))
        XCTAssertNil(TraktProgressService.normalizedProgress(.infinity))
    }

    func testWatchedSeedRetiresOnlyMatchingOlderPauseAndPreservesRewatch() {
        let now = Date()
        func seed(_ id: String = "fixture", episode: Int = 3, time: Date, watched: Bool) -> TraktProgressSeed {
            TraktProgressSeed(contentID: id, type: "series", title: "Fixture", year: nil,
                progressPercent: watched ? 0 : 40, lastUpdated: time, season: 1,
                episode: episode, episodeTitle: nil, isUpNext: watched, ids: nil)
        }
        let pause = seed(time: now, watched: false)
        XCTAssertTrue(TraktProgressService.completedSeedSupersedesPlayback(seed(time: now, watched: true), playback: pause))
        XCTAssertTrue(TraktProgressService.completedSeedSupersedesPlayback(seed(time: now.addingTimeInterval(5), watched: true), playback: pause))
        XCTAssertFalse(TraktProgressService.completedSeedSupersedesPlayback(seed(time: now.addingTimeInterval(-5), watched: true), playback: pause))
        XCTAssertFalse(TraktProgressService.completedSeedSupersedesPlayback(seed(episode: 4, time: now, watched: true), playback: pause))
        XCTAssertFalse(TraktProgressService.completedSeedSupersedesPlayback(seed("other", time: now, watched: true), playback: pause))
    }

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousContinueWatchingProfileID = ContinueWatchingStore.activeProfileId
        profileA = "trakt-cw-a-\(UUID().uuidString)"
        profileB = "trakt-cw-b-\(UUID().uuidString)"
        activate(profileA)
    }

    override func tearDown() async throws {
        await MainActor.run {
            for profileID in [profileA, profileB] {
                activate(profileID)
                TraktProgressService.forgetLocalPlayback(meta: checkpointMeta, notify: false)
                TraktProgressService.forgetLocalPlayback(meta: remoteMeta, notify: false)
                UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
            }
            ContinueWatchingStore.setActiveProfile(previousContinueWatchingProfileID)
            if let previousSettingsProfileID {
                ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
        }
        try await super.tearDown()
    }

    @MainActor
    func testOldProfileResultsCannotMergeNewProfileCheckpointsOrPublishSnapshot() {
        let context = capture()
        activate(profileB)
        seedCheckpoint()

        let result = TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation(), item(meta: remoteMeta)], context: context
        )

        XCTAssertNil(result)
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testSettingsProfileSwitchAloneRejectsResultsBeforeCheckpointReconciliation() {
        let context = capture()
        seedCheckpoint()
        ProfileSettings.setActiveProfile(profileB, isPrimary: false)

        XCTAssertNil(TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation(), item(meta: remoteMeta)], context: context
        ))
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testSourceSwitchRejectsDisplayedResultsBeforeCheckpointReconciliation() {
        let context = capture()
        seedCheckpoint()
        ProfileSettings.current.set(TraktWatchProgressSource.nuvioSync.rawValue,
                                    forKey: SettingsKey.traktWatchProgressSource)

        XCTAssertNil(TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation(), item(meta: remoteMeta)], context: context
        ))
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testCurrentProfileResultsStillMergeAndPublish() {
        seedCheckpoint()
        let remote = item(meta: remoteMeta)
        let result = TraktProgressService.finalizeContinueWatchingFetch([remote], context: capture())

        XCTAssertEqual(Set(result?.map { $0.meta.id } ?? []), Set([checkpointMeta.id, remoteMeta.id]))
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertEqual(current(remoteMeta)?.position, remote.position)
    }

    @MainActor
    func testReadOnlyOverrideReturnsProviderItemsWithoutMergingOrPublishing() {
        seedCheckpoint()
        ProfileSettings.current.set(TraktWatchProgressSource.nuvioSync.rawValue,
                                    forKey: SettingsKey.traktWatchProgressSource)
        let remote = item(meta: remoteMeta)
        let result = TraktProgressService.finalizeContinueWatchingFetch(
            [remote], context: capture(updateDisplayedSnapshot: false)
        )

        XCTAssertEqual(result?.map { $0.meta.id }, [remoteMeta.id])
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testCancelledResultCannotReconcileOrPublish() async {
        seedCheckpoint()
        let context = capture()
        let items = [remoteConfirmation(), item(meta: remoteMeta)]
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return TraktProgressService.finalizeContinueWatchingFetch(items, context: context)
        }
        let result = await task.value

        XCTAssertNil(result)
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    private func capture(updateDisplayedSnapshot: Bool = true) -> TraktProgressService.ContinueWatchingFetchContext {
        TraktProgressService.ContinueWatchingFetchContext(source: .trakt,
                                                       updateDisplayedSnapshot: updateDisplayedSnapshot)
    }

    private var checkpointMeta: NuvioMeta { NuvioMeta(id: "cw-checkpoint-\(profileA)", name: "Local", type: "movie") }
    private var remoteMeta: NuvioMeta { NuvioMeta(id: "cw-remote-\(profileA)", name: "Remote", type: "movie") }

    private func activate(_ profileID: String) {
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        ContinueWatchingStore.setActiveProfile(profileID)
        ProfileSettings.current.set(TraktWatchProgressSource.trakt.rawValue,
                                    forKey: SettingsKey.traktWatchProgressSource)
    }

    @MainActor
    private func seedCheckpoint() {
        TraktProgressService.recordLocalPlayback(meta: checkpointMeta, position: 300, duration: 1000,
                                                season: nil, episode: nil, source: .trakt, notify: false)
    }

    private func item(meta: NuvioMeta, position: Double = 100, date: Date = Date()) -> ContinueWatchingItem {
        ContinueWatchingItem(meta: meta, streamUrl: "", position: position, duration: 1000,
                             lastWatchedAt: date, season: nil, episode: nil)
    }

    private func remoteConfirmation() -> ContinueWatchingItem {
        // If stale reconciliation runs, this newer/further row removes the
        // current profile's local checkpoint as server-confirmed progress.
        item(meta: checkpointMeta, position: 800, date: Date().addingTimeInterval(60))
    }

    @MainActor
    private func current(_ meta: NuvioMeta) -> ContinueWatchingItem? {
        TraktProgressService.currentContinueWatchingItem(for: meta, source: .trakt)
    }
}

extension TraktContinueWatchingOwnershipTests {
    @MainActor
    func testDelayedProviderResponsePreservesNewerUnsynchronisedCheckpoint() {
        let context = capture()
        seedCheckpoint()
        let stale = item(meta: checkpointMeta, position: 100, date: Date(timeIntervalSince1970: 1))
        let result = TraktProgressService.finalizeContinueWatchingFetch([stale], context: context)
        XCTAssertEqual(result?.first?.position, 300)
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
    }
}


extension TraktContinueWatchingOwnershipTests {
    // These tests exercise the same durable-store -> optimistic progress ->
    // already-mounted Home/Details projection path used after an Infuse return.
    @MainActor
    func testNaturalE3CompletionRetiresResumeAndSelectsE4WithoutNavigation() {
        let prior = WatchedStore.activeProfileId
        WatchedStore.setActiveProfile(profileA)
        let show = NuvioMeta(id: "vision-natural-\(profileA)", name: "VisionQuest", type: "series")
        defer {
            TraktProgressService.forgetLocalPlayback(meta: show, notify: false)
            WatchedStore.eraseProfile(profileA)
            WatchedStore.setActiveProfile(prior)
        }

        let started = Date().addingTimeInterval(-180)
        let watchedAt = started.addingTimeInterval(80)
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 840, duration: 0, season: 1, episode: 3,
            source: .trakt, notify: false, preservesExactPosition: true,
            recordedAt: started.addingTimeInterval(60), playbackStartedAt: started
        ))
        let e3Pause = ContinueWatchingItem(
            meta: show, streamUrl: "", position: 0, duration: 0,
            lastWatchedAt: started.addingTimeInterval(70), season: 1, episode: 3,
            explicitProgressPercent: 42
        )
        let e4Next = ContinueWatchingItem(
            meta: show, streamUrl: "", position: 1, duration: 0,
            lastWatchedAt: watchedAt, season: 1, episode: 4,
            isUpNext: true, upNextSeedSeason: 1
        )
        XCTAssertEqual(TraktProgressService.finalizeContinueWatchingFetch(
            [e3Pause], context: capture()
        )?.first?.episode, 3)

        let mark = WatchedStoreItem(
            meta: show, watchedAt: watchedAt, season: 1, episode: 3,
            sources: [TraktWatchProgressSource.trakt.rawValue]
        )
        XCTAssertTrue(WatchedStore.reconcileTraktSnapshot(
            [mark], syncStartedAt: Date(), currentAccountID: nil
        ))
        TraktProgressService.reconcileTraktWatchedHistory(profileId: profileA)
        XCTAssertNil(TraktProgressService.currentContinueWatchingItem(for: show, source: .trakt))
        let result = TraktProgressService.finalizeContinueWatchingFetch(
            [e3Pause, e4Next], context: capture()
        )
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.episode, 4)
        XCTAssertTrue(result?.first?.isUpNextEntry == true)
        XCTAssertEqual(current(show)?.episode, 4)
    }

    @MainActor
    func testHistoryBeforeFinalInfuseCallbackDoesNotResurrectE3() {
        let prior = WatchedStore.activeProfileId
        WatchedStore.setActiveProfile(profileA)
        let show = NuvioMeta(id: "vision-watched-first-\(profileA)", name: "VisionQuest", type: "series")
        defer {
            TraktProgressService.forgetLocalPlayback(meta: show, notify: false)
            WatchedStore.eraseProfile(profileA)
            WatchedStore.setActiveProfile(prior)
        }
        let watchedAt = Date().addingTimeInterval(-90)
        let mark = WatchedStoreItem(meta: show, watchedAt: watchedAt, season: 1, episode: 3,
                                    sources: [TraktWatchProgressSource.trakt.rawValue])
        XCTAssertTrue(WatchedStore.reconcileTraktSnapshot(
            [mark], syncStartedAt: Date(), currentAccountID: nil
        ))
        TraktProgressService.reconcileTraktWatchedHistory(profileId: profileA)

        // The receipt timestamp is AFTER the watched event; the handoff start
        // is BEFORE it. This is not a later independent rewatch.
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 1950, duration: 0, season: 1, episode: 3,
            source: .trakt, notify: true, preservesExactPosition: true,
            recordedAt: watchedAt.addingTimeInterval(20),
            playbackStartedAt: watchedAt.addingTimeInterval(-45)
        ))
        let delayedPause = ContinueWatchingItem(meta: show, streamUrl: "", position: 0,
            duration: 0, lastWatchedAt: watchedAt.addingTimeInterval(10),
            season: 1, episode: 3, explicitProgressPercent: 10)
        let e4 = ContinueWatchingItem(meta: show, streamUrl: "", position: 1,
            duration: 0, lastWatchedAt: watchedAt, season: 1, episode: 4, isUpNext: true)
        XCTAssertEqual(TraktProgressService.mergingLocalPlaybackCheckpoints(
            into: [delayedPause, e4], source: .trakt
        ).map(\.episode), [4])
        TraktProgressService.reloadCheckpointsForTesting()
        XCTAssertEqual(TraktProgressService.finalizeContinueWatchingFetch(
            [delayedPause, e4], context: capture()
        )?.map(\.episode), [4], "The retirement fence must survive a disk reload")
    }

    @MainActor
    func testRepeatedIdenticalWatchedSnapshotRepairsOlderProgress() {
        let prior = WatchedStore.activeProfileId
        WatchedStore.setActiveProfile(profileA)
        let show = NuvioMeta(id: "vision-repeat-\(profileA)", name: "VisionQuest", type: "series")
        defer {
            TraktProgressService.forgetLocalPlayback(meta: show, notify: false)
            WatchedStore.eraseProfile(profileA)
            WatchedStore.setActiveProfile(prior)
        }
        let watchedAt = Date().addingTimeInterval(-30)
        let mark = WatchedStoreItem(meta: show, watchedAt: watchedAt, season: 1, episode: 3,
                                    sources: [TraktWatchProgressSource.trakt.rawValue])
        WatchedStore.replaceAll([mark])
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 240, duration: 0, season: 1, episode: 3,
            source: .trakt, notify: false, preservesExactPosition: true,
            recordedAt: watchedAt.addingTimeInterval(-30),
            playbackStartedAt: watchedAt.addingTimeInterval(-60)
        ))
        XCTAssertTrue(WatchedStore.reconcileTraktSnapshot(
            [mark], syncStartedAt: Date(), currentAccountID: nil
        ))
        TraktProgressService.reconcileTraktWatchedHistory(profileId: profileA)
        TraktProgressService.reconcileTraktWatchedHistory(profileId: profileA)
        XCTAssertNil(current(show))
    }

    @MainActor
    func testLaterRewatchAndCrossDeviceRewindBeatCompletedHandoff() {
        let prior = WatchedStore.activeProfileId
        WatchedStore.setActiveProfile(profileA)
        let show = NuvioMeta(id: "vision-rewatch-\(profileA)", name: "VisionQuest", type: "series")
        defer {
            TraktProgressService.forgetLocalPlayback(meta: show, notify: false)
            WatchedStore.eraseProfile(profileA)
            WatchedStore.setActiveProfile(prior)
        }
        let watchedAt = Date().addingTimeInterval(-300)
        WatchedStore.replaceAll([WatchedStoreItem(
            meta: show, watchedAt: watchedAt, season: 1, episode: 3,
            sources: [TraktWatchProgressSource.trakt.rawValue]
        )])
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 1850, duration: 0, season: 1, episode: 3,
            source: .trakt, notify: false, preservesExactPosition: true,
            recordedAt: watchedAt.addingTimeInterval(10),
            playbackStartedAt: watchedAt.addingTimeInterval(-90)
        ))
        _ = TraktProgressService.mergingLocalPlaybackCheckpoints(into: [], source: .trakt)

        let newerRewind = ContinueWatchingItem(
            meta: show, streamUrl: "", position: 0, duration: 0,
            lastWatchedAt: watchedAt.addingTimeInterval(120), season: 1,
            episode: 3, explicitProgressPercent: 8
        )
        XCTAssertEqual(TraktProgressService.mergingLocalPlaybackCheckpoints(
            into: [newerRewind], source: .trakt
        ).first?.explicitProgressPercent, 8)
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 370, duration: 0, season: 1, episode: 3,
            source: .trakt, notify: false, preservesExactPosition: true,
            recordedAt: watchedAt.addingTimeInterval(240),
            playbackStartedAt: watchedAt.addingTimeInterval(180)
        ))
        XCTAssertEqual(TraktProgressService.mergingLocalPlaybackCheckpoints(
            into: [], source: .trakt
        ).first?.position, 370)
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 650, duration: 0, season: 1, episode: 4,
            source: .trakt, notify: false, preservesExactPosition: true,
            recordedAt: watchedAt.addingTimeInterval(260),
            playbackStartedAt: watchedAt.addingTimeInterval(250)
        ))
        let checkpoints = TraktProgressService.mergingLocalPlaybackCheckpoints(
            into: [], source: .trakt
        )
        XCTAssertEqual(Set(checkpoints.compactMap(\.episode)), Set([3, 4]))
    }

    @MainActor
    func testDistinctEpisodeCheckpointsSurviveReconciliationWithAnotherEpisodeRemoteRow() {
        let show = NuvioMeta(id: "episode-identity-\(profileA)", name: "Episode identity", type: "series")
        defer { TraktProgressService.forgetLocalPlayback(meta: show, notify: false) }
        let now = Date()
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 303, duration: 0, season: 1, episode: 3,
            source: .trakt, notify: false, preservesExactPosition: true,
            recordedAt: now.addingTimeInterval(-20), playbackStartedAt: now.addingTimeInterval(-50)
        ))
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 404, duration: 0, season: 1, episode: 4,
            source: .trakt, notify: false, preservesExactPosition: true,
            recordedAt: now.addingTimeInterval(-10), playbackStartedAt: now.addingTimeInterval(-30)
        ))
        let remoteE4 = ContinueWatchingItem(
            meta: show, streamUrl: "", position: 0, duration: 0,
            lastWatchedAt: now.addingTimeInterval(-15), season: 1, episode: 4,
            explicitProgressPercent: 22
        )
        for _ in 0..<2 {
            let items = TraktProgressService.mergingLocalPlaybackCheckpoints(
                into: [remoteE4], source: .trakt
            )
            XCTAssertEqual(Set(items.compactMap(\.episode)), Set([3, 4]))
            XCTAssertEqual(items.first(where: { $0.episode == 3 })?.position, 303)
            XCTAssertEqual(items.first(where: { $0.episode == 4 })?.position, 404)
        }
        TraktProgressService.reloadCheckpointsForTesting()
        let persisted = TraktProgressService.mergingLocalPlaybackCheckpoints(into: [], source: .trakt)
        XCTAssertEqual(Set(persisted.compactMap(\.episode)), Set([3, 4]))
    }

    @MainActor
    func testNewerRemoteEpisodeRewindDoesNotDeleteDifferentEpisode() {
        let show = NuvioMeta(id: "rewind-isolation-\(profileA)", name: "Rewind", type: "series")
        defer { TraktProgressService.forgetLocalPlayback(meta: show, notify: false) }
        let now = Date()
        for episode in [3, 4] {
            XCTAssertTrue(TraktProgressService.recordLocalPlayback(
                meta: show, position: Double(episode * 100), duration: 0,
                season: 1, episode: episode, source: .trakt, notify: false,
                preservesExactPosition: true, recordedAt: now.addingTimeInterval(-120),
                playbackStartedAt: now.addingTimeInterval(-180)
            ))
        }
        let rewindE3 = ContinueWatchingItem(
            meta: show, streamUrl: "", position: 0, duration: 0,
            lastWatchedAt: now, season: 1, episode: 3,
            explicitProgressPercent: 8
        )
        let result = TraktProgressService.mergingLocalPlaybackCheckpoints(
            into: [rewindE3], source: .trakt
        )
        XCTAssertEqual(result.first(where: { $0.episode == 3 })?.explicitProgressPercent, 8)
        XCTAssertEqual(result.first(where: { $0.episode == 4 })?.position, 400)
        XCTAssertEqual(
            TraktProgressService.mergingLocalPlaybackCheckpoints(into: [], source: .trakt)
                .first(where: { $0.episode == 4 })?.position, 400
        )
    }

    @MainActor
    func testPartialExternalCheckpointNotifiesMountedViewsAndKeepsExactSeconds() {
        let show = NuvioMeta(id: "partial-update-\(profileA)", name: "Partial", type: "series")
        defer { TraktProgressService.forgetLocalPlayback(meta: show, notify: false) }
        let published = expectation(
            forNotification: TraktSettingsStore.continueWatchingChangedNotification, object: nil
        )
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 913.5, duration: 0, season: 1, episode: 3,
            source: .trakt, notify: true, preservesExactPosition: true
        ))
        wait(for: [published], timeout: 1) // Publication is synchronous after the durable write.
        XCTAssertEqual(current(show)?.position, 913.5)
        TraktProgressService.reloadCheckpointsForTesting()
        XCTAssertEqual(current(show)?.resumePosition, 913.5)
    }

    @MainActor
    func testCompletedSessionFenceAllowsNextUpAgainstLaterSameHandoffPause() {
        let prior = WatchedStore.activeProfileId
        WatchedStore.setActiveProfile(profileA)
        let show = NuvioMeta(id: "seed-fence-\(profileA)", name: "VisionQuest", type: "series")
        defer {
            TraktProgressService.forgetLocalPlayback(meta: show, notify: false)
            WatchedStore.eraseProfile(profileA)
            WatchedStore.setActiveProfile(prior)
        }
        let watchedAt = Date().addingTimeInterval(-240)
        WatchedStore.replaceAll([WatchedStoreItem(
            meta: show, watchedAt: watchedAt, season: 1, episode: 3,
            sources: [TraktWatchProgressSource.trakt.rawValue]
        )])
        XCTAssertTrue(TraktProgressService.recordLocalPlayback(
            meta: show, position: 1450, duration: 0, season: 1, episode: 3,
            source: .trakt, notify: false, preservesExactPosition: true,
            recordedAt: watchedAt.addingTimeInterval(15),
            playbackStartedAt: watchedAt.addingTimeInterval(-60)
        ))
        _ = TraktProgressService.mergingLocalPlaybackCheckpoints(into: [], source: .trakt)
        func seed(at date: Date, watched: Bool) -> TraktProgressSeed {
            TraktProgressSeed(
                contentID: show.id, type: "series", title: "VisionQuest", year: nil,
                progressPercent: watched ? 0 : 30, lastUpdated: date,
                season: 1, episode: 3, episodeTitle: nil, isUpNext: watched, ids: nil
            )
        }
        let completion = seed(at: watchedAt, watched: true)
        let latePause = seed(at: watchedAt.addingTimeInterval(10), watched: false)
        let realRewatch = seed(at: watchedAt.addingTimeInterval(90), watched: false)
        XCTAssertFalse(TraktProgressService.completedSeedSupersedesPlayback(completion, playback: latePause))
        XCTAssertTrue(TraktProgressService.completedSessionSupersedesPlayback(
            completion, playback: latePause, profileId: profileA, accountID: nil
        ))
        XCTAssertFalse(TraktProgressService.completedSessionSupersedesPlayback(
            completion, playback: realRewatch, profileId: profileA, accountID: nil
        ))
    }

    @MainActor
    func testOlderInFlightProviderFetchCannotReplaceNewerSnapshot() {
        let older = capture()
        let newer = capture()
        let fresh = item(meta: remoteMeta, position: 800)
        XCTAssertEqual(TraktProgressService.finalizeContinueWatchingFetch(
            [fresh], context: newer
        )?.first?.position, 800)
        XCTAssertNil(TraktProgressService.finalizeContinueWatchingFetch(
            [item(meta: remoteMeta, position: 90)], context: older
        ))
        XCTAssertEqual(current(remoteMeta)?.position, 800)
    }
}
