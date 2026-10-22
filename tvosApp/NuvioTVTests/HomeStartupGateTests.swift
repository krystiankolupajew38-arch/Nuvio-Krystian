import XCTest
@testable import NuvioTV

final class HomeStartupGateTests: XCTestCase {
    func testPrivateHomeCatalogCacheIsAccountProfileAndConfigurationScoped() {
        let section = TVHomeSection(
            id: "catalog-test", title: "Catalog",
            items: [NuvioMeta(id: "tt1234567", type: "movie", name: "Example")]
        )
        let firstAccount = "cache-account-a"
        let profile = "cache-profile-a"
        let configuration = "cache-config-a"
        defer { TVHomePresentationCache.remove(accountScope: firstAccount, profileID: profile) }
        XCTAssertTrue(TVHomePresentationCache.store(
            rows: [section], accountScope: firstAccount,
            profileID: profile, configuration: configuration
        ))
        let restored = TVHomePresentationCache.restore(
            accountScope: firstAccount, profileID: profile, configuration: configuration
        )
        XCTAssertEqual(restored?.first?.items.first?.id, "tt1234567")
        XCTAssertNil(TVHomePresentationCache.restore(
            accountScope: "cache-account-b", profileID: profile, configuration: configuration
        ))
        XCTAssertNil(TVHomePresentationCache.restore(
            accountScope: firstAccount, profileID: "cache-profile-b", configuration: configuration
        ))
        XCTAssertNil(TVHomePresentationCache.restore(
            accountScope: firstAccount, profileID: profile, configuration: "changed-config"
        ))
    }

    func testPrivateHomeCatalogCacheExpiresAndRejectsFutureSnapshots() {
        let account = "cache-expiration-a"
        let profile = "cache-expiration-profile"
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        defer { TVHomePresentationCache.remove(accountScope: account, profileID: profile) }
        let section = TVHomeSection(
            id: "catalog-test", title: "Catalog",
            items: [NuvioMeta(id: "tt1234568", type: "movie", name: "Example")]
        )
        XCTAssertTrue(TVHomePresentationCache.store(
            rows: [section], accountScope: account, profileID: profile,
            configuration: "config", now: base
        ))
        XCTAssertNotNil(TVHomePresentationCache.restore(
            accountScope: account, profileID: profile, configuration: "config",
            now: base.addingTimeInterval(1)
        ))
        XCTAssertNil(TVHomePresentationCache.restore(
            accountScope: account, profileID: profile, configuration: "config",
            now: base.addingTimeInterval(TVHomePresentationCache.lifetime + 1)
        ))
        XCTAssertNil(TVHomePresentationCache.restore(
            accountScope: account, profileID: profile, configuration: "config",
            now: base.addingTimeInterval(-1)
        ))
    }

    func testCatalogReadinessCanReleaseBeforeRemoteProgressCompletes() {
        var gate = TVHomeStartupGate()
        XCTAssertFalse(gate.update(elapsed: 0.2, isReady: false))
        // isReady comes from first focusable catalog OR fully settled progress.
        XCTAssertFalse(gate.update(elapsed: 0.4, isReady: true))
        XCTAssertTrue(gate.update(elapsed: 0.9, isReady: true))
        XCTAssertTrue(gate.update(elapsed: 1.2, isReady: false))
    }

    func testCatalogsArrivingBeforeProgressDoNotRevealHome() {
        var gate = TVHomeStartupGate()
        XCTAssertFalse(gate.update(elapsed: 1, isReady: false))
        XCTAssertFalse(gate.update(elapsed: 3, isReady: true))
        XCTAssertFalse(gate.update(elapsed: 3.4, isReady: true))
        XCTAssertTrue(gate.update(elapsed: 3.5, isReady: true))
    }

    func testNewProgressWorkRestartsSettlingButNotDeadline() {
        var gate = TVHomeStartupGate()
        XCTAssertFalse(gate.update(elapsed: 1, isReady: true))
        XCTAssertFalse(gate.update(elapsed: 1.4, isReady: false))
        XCTAssertFalse(gate.update(elapsed: 1.5, isReady: true))
        XCTAssertFalse(gate.update(elapsed: 1.9, isReady: true))
        XCTAssertTrue(gate.update(elapsed: 2, isReady: true))
    }

    func testSlowOrFailedProviderCannotHoldHomeIndefinitely() {
        var gate = TVHomeStartupGate()
        XCTAssertFalse(gate.update(elapsed: 7.9, isReady: false))
        XCTAssertTrue(gate.update(elapsed: 8, isReady: false))
    }

    func testBackgroundRefreshCannotCoverRevealedHome() {
        var gate = TVHomeStartupGate()
        XCTAssertFalse(gate.update(elapsed: 0, isReady: true))
        XCTAssertTrue(gate.update(elapsed: 0.5, isReady: true))
        XCTAssertTrue(gate.update(elapsed: 1, isReady: false))
    }

    @MainActor
    func testStoreKeepsRevealedHomeDuringReloadAndClearsItOnReset() {
        let store = TVHomeStore()
        let identity = TVHomeContentIdentity(profileId: "startup-test", catalogRevision: 0)
        let first = store.beginLoad(for: identity)
        store.finishLoad(first, for: identity)
        store.hasPresentedHome = true
        _ = store.beginLoad(for: identity)
        XCTAssertTrue(store.hasPresentedHome)
        _ = store.beginLoad(for: TVHomeContentIdentity(profileId: "other-profile", catalogRevision: 0))
        XCTAssertFalse(store.hasPresentedHome)
        store.hasPresentedHome = true
        store.reset()
        XCTAssertFalse(store.hasPresentedHome)
    }
}
