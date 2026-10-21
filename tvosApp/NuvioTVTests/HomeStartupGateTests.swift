import XCTest
@testable import NuvioTV

final class HomeStartupGateTests: XCTestCase {
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
