import Foundation
@testable import UntoldSharePlay
import XCTest

/// The SwiftUI actions, scripted: opens resolve with the queued results,
/// dismisses complete when the test says so.
@MainActor
final class FakeSpace {
    var openResults: [ImmersiveSpaceCoordinator.OpenResult] = [.opened]
    private(set) var opens = 0
    private(set) var dismisses = 0
    private var openContinuation: CheckedContinuation<ImmersiveSpaceCoordinator.OpenResult, Never>?
    private var dismissContinuation: CheckedContinuation<Void, Never>?

    func bind(_ coordinator: ImmersiveSpaceCoordinator) {
        coordinator.bind(open: { [self] in
            opens += 1
            return await withCheckedContinuation { openContinuation = $0 }
        }, dismiss: { [self] in
            dismisses += 1
            await withCheckedContinuation { dismissContinuation = $0 }
        })
    }

    var openPending: Bool {
        openContinuation != nil
    }

    var dismissPending: Bool {
        dismissContinuation != nil
    }

    func finishOpen() {
        let result = openResults.isEmpty ? .opened : openResults.removeFirst()
        openContinuation?.resume(returning: result)
        openContinuation = nil
    }

    func finishDismiss() {
        dismissContinuation?.resume()
        dismissContinuation = nil
    }
}

@MainActor
final class ImmersiveSpaceCoordinatorTests: XCTestCase {
    func testOpenAndDismissWithTeardown() async throws {
        let coordinator = ImmersiveSpaceCoordinator(id: "Arena")
        let space = FakeSpace()
        coordinator.open(reason: "unbound") // dropped
        space.bind(coordinator)
        coordinator.open(reason: "button")
        XCTAssertEqual(coordinator.phase, .opening)
        try await waitUntil { space.openPending }
        coordinator.open(reason: "again") // ignored while opening
        XCTAssertEqual(space.opens, 1)
        space.finishOpen()
        try await waitUntil { coordinator.phase == .open }
        coordinator.spaceDidStart()
        XCTAssertEqual(coordinator.phaseLabel, "OPEN")

        coordinator.dismiss(reason: "button")
        XCTAssertEqual(coordinator.phase, .closing)
        try await waitUntil { space.dismissPending }
        space.finishDismiss()
        try await waitUntil { coordinator.phase == .closed }
        XCTAssertTrue(coordinator.isTearingDown)
        // An open during the teardown waits for it.
        coordinator.open(reason: "early")
        XCTAssertEqual(space.opens, 1)
        coordinator.spaceDidTearDown()
        try await waitUntil { space.opens == 2 }
        XCTAssertEqual(coordinator.phase, .opening)
        space.finishOpen()
        try await waitUntil { coordinator.phase == .open }
    }

    func testWithoutTeardownTrackingTheSpaceClosesWhenDismissed() async throws {
        let coordinator = ImmersiveSpaceCoordinator(id: "Room", tracksTeardown: false)
        let space = FakeSpace()
        space.bind(coordinator)
        coordinator.open(reason: "button")
        try await waitUntil { space.openPending }
        space.finishOpen()
        try await waitUntil { coordinator.phase == .open }
        coordinator.dismiss(reason: "button")
        try await waitUntil { space.dismissPending }
        space.finishDismiss()
        try await waitUntil { coordinator.phase == .closed }
        XCTAssertFalse(coordinator.isTearingDown)
        coordinator.open(reason: "again")
        XCTAssertEqual(coordinator.phase, .opening)
    }

    func testDismissWhileOpeningIsDeferred() async throws {
        let coordinator = ImmersiveSpaceCoordinator(id: "Arena")
        let space = FakeSpace()
        space.bind(coordinator)
        coordinator.open(reason: "button")
        coordinator.dismiss(reason: "system")
        XCTAssertEqual(coordinator.phase, .opening)
        try await waitUntil { space.openPending }
        space.finishOpen()
        try await waitUntil { coordinator.phase == .closing }
        XCTAssertEqual(space.dismisses, 1)
    }

    func testJoinGroupCyclesAnOpenSpaceOnce() async throws {
        let coordinator = ImmersiveSpaceCoordinator(id: "Arena")
        let space = FakeSpace()
        space.bind(coordinator)
        coordinator.joinGroup(reason: "join") // closed: opens
        try await waitUntil { space.openPending }
        space.finishOpen()
        try await waitUntil { coordinator.phase == .open }

        coordinator.joinGroup(reason: "immersion") // within the guard: ignored
        XCTAssertEqual(coordinator.phase, .open)
        coordinator.joinCycleGuard = 0
        coordinator.joinGroup(reason: "immersion")
        XCTAssertEqual(coordinator.phase, .closing)
        try await waitUntil { space.dismissPending }
        space.finishDismiss()
        try await waitUntil { coordinator.phase == .closed }
        coordinator.spaceDidTearDown()
        try await waitUntil { space.opens == 2 } // reopened as the shared space
    }

    func testOpenErrorRetriesOnceWhenAnOpenIsPending() async throws {
        let coordinator = ImmersiveSpaceCoordinator(id: "Arena")
        let space = FakeSpace()
        space.openResults = [.error, .opened]
        space.bind(coordinator)
        coordinator.open(reason: "button")
        coordinator.joinGroup(reason: "join") // opening: dismiss + open pending
        try await waitUntil { space.openPending }
        space.finishOpen() // error
        try await waitUntil { space.opens == 2 }
        XCTAssertEqual(coordinator.lastOpenResult, "error")
        space.finishOpen()
        try await waitUntil { coordinator.phase == .open }
    }

    func testEmptyPresentedSpaceIsRecovered() async throws {
        let coordinator = ImmersiveSpaceCoordinator(id: "Arena")
        let space = FakeSpace()
        space.bind(coordinator)
        coordinator.open(reason: "button")
        try await waitUntil { space.openPending }
        space.finishOpen()
        try await waitUntil { coordinator.phase == .open }
        coordinator.spaceDidStart(rendering: false)
        XCTAssertTrue(coordinator.presentedEmpty)
        XCTAssertEqual(coordinator.phase, .closing, "recovered by a dismiss at once")
        try await waitUntil { space.dismissPending }
        space.finishDismiss()
        try await waitUntil { coordinator.phase == .closed }
        coordinator.spaceDidTearDown()
        try await waitUntil { space.opens == 2 } // the deferred reopen
        XCTAssertFalse(coordinator.presentedEmpty)
    }

    func testSessionDrivesTheCoordinator() async throws {
        let hub = LoopbackHub()
        var configuration = SharePlaySession.Configuration()
        configuration.stateRate = 200
        let a = SharePlaySession(transport: hub.makeTransport(id: participantID(1)), configuration: configuration)
        let b = SharePlaySession(transport: hub.makeTransport(id: participantID(2)), configuration: configuration)
        let coordinator = ImmersiveSpaceCoordinator(id: "Arena")
        let space = FakeSpace()
        space.bind(coordinator)
        a.drive(coordinator)
        a.startObserving()
        b.startObserving()
        _ = await a.start()
        try await waitUntil { a.state == .joined && b.state == .joined }
        try await waitUntil { space.openPending } // the join opened the space
        space.finishOpen()
        try await waitUntil { coordinator.phase == .open }
        coordinator.joinCycleGuard = 0
        let sessionA = try XCTUnwrap(hub.session(for: participantID(1)))
        sessionA.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, groupImmersion: .requested(.mixed)))
        try await waitUntil { coordinator.phase == .closing } // cycled to become shared
        try await waitUntil { space.dismissPending }
        space.finishDismiss()
        coordinator.spaceDidTearDown()
        try await waitUntil { space.opens == 2 }
        space.finishOpen()
        try await waitUntil { coordinator.phase == .open }
        sessionA.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, groupImmersion: .ended))
        try await waitUntil { coordinator.phase == .closing }
        a.leave()
    }
}
