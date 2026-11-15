import Foundation
import simd
@testable import UntoldSharePlay
import XCTest

/// What a RealityView space taught the plugin (Oche, 2026-10-29 and
/// 2026-11-15): the system echoes a participant's open as the group's
/// request and reports the group's end during the app's own dismiss; the
/// scene is the shared frame and ARKit's frame at once, so nothing of the
/// space's displacement is applied; the seats stand in a row facing the
/// content.
@MainActor
final class RealityViewSpaceTests: XCTestCase {
    /// SwiftUI's open and dismiss, completing at once and counted.
    @MainActor
    final class ScriptedSpace {
        private(set) var opens = 0
        private(set) var dismisses = 0

        func bind(_ coordinator: ImmersiveSpaceCoordinator) {
            coordinator.bind(open: { [self] in
                opens += 1
                return .opened
            }, dismiss: { [self] in
                dismisses += 1
            })
        }
    }

    private func makePair() -> (hub: LoopbackHub, a: SharePlaySession, b: SharePlaySession) {
        let hub = LoopbackHub()
        var configuration = SharePlaySession.Configuration()
        configuration.stateRate = 200
        let a = SharePlaySession(transport: hub.makeTransport(id: participantID(1)), configuration: configuration)
        let b = SharePlaySession(transport: hub.makeTransport(id: participantID(2)), configuration: configuration)
        a.startObserving()
        b.startObserving()
        return (hub, a, b)
    }

    private func join(_ a: SharePlaySession, _ b: SharePlaySession) async throws {
        _ = await a.start()
        try await waitUntil { a.state == .joined && b.state == .joined && a.others.count == 1 }
    }

    func testASpaceOpenedAfterTheJoinStaysOpenThroughTheGroupsReports() async throws {
        let (hub, a, b) = makePair()
        let coordinator = ImmersiveSpaceCoordinator(id: "Room", tracksTeardown: false)
        let space = ScriptedSpace()
        space.bind(coordinator)
        a.drive(coordinator)
        try await join(a, b)

        coordinator.open(reason: "the player")
        try await waitUntil { coordinator.phase == .open }
        coordinator.spaceDidStart()
        let transport = try XCTUnwrap(hub.session(for: participantID(1)))
        // The system echoes our open as the group's request: nothing to cycle.
        transport.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, groupImmersion: .requested(.mixed)))
        try await waitUntil { a.groupImmersion == .requested(.mixed) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.phase, .open)
        XCTAssertEqual(space.dismisses, 0)
        XCTAssertEqual(space.opens, 1)
        // The group leaves its space: ours is dismissed (the default).
        transport.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, groupImmersion: .ended))
        try await waitUntil { coordinator.phase == .closed }
        XCTAssertEqual(space.dismisses, 1)
        a.leave()
        b.leave()
    }

    func testTheGroupsEndDuringTheJoinCycleDoesNotCancelTheReopen() async throws {
        let (hub, a, b) = makePair()
        let coordinator = ImmersiveSpaceCoordinator(id: "Room", tracksTeardown: true)
        let space = ScriptedSpace()
        space.bind(coordinator)
        a.drive(coordinator)
        coordinator.open(reason: "before the join")
        try await waitUntil { coordinator.phase == .open }
        coordinator.spaceDidStart()

        try await join(a, b)
        // The join cycles the private space: dismissed, teardown pending.
        try await waitUntil { space.dismisses == 1 && coordinator.phase == .closed }
        XCTAssertTrue(coordinator.isCycling)
        // While our own dismiss runs the system reports the group's end.
        let transport = try XCTUnwrap(hub.session(for: participantID(1)))
        transport.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, groupImmersion: .ended))
        try await waitUntil { a.groupImmersion == .ended }
        coordinator.spaceDidTearDown()
        try await waitUntil { space.opens == 2 && coordinator.phase == .open }
        XCTAssertFalse(coordinator.isCycling)
        a.leave()
        b.leave()
    }

    func testAGameMayKeepItsRoomWhenTheGroupLeavesItsSpace() async throws {
        let (hub, a, b) = makePair()
        let coordinator = ImmersiveSpaceCoordinator(id: "Room", tracksTeardown: false)
        let space = ScriptedSpace()
        space.bind(coordinator)
        a.drive(coordinator, dismissesOnGroupEnd: false)
        try await join(a, b)
        coordinator.open(reason: "the player")
        try await waitUntil { coordinator.phase == .open }
        coordinator.spaceDidStart()
        let transport = try XCTUnwrap(hub.session(for: participantID(1)))
        transport.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, groupImmersion: .ended))
        try await waitUntil { a.groupImmersion == .ended }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.phase, .open)
        XCTAssertEqual(space.dismisses, 0)
        a.leave()
        b.leave()
    }

    /// A RealityView scene is the shared frame: a shared point is a local
    /// point, whatever seat the system reports and wherever the head is,
    /// and it stays so through a session's end. (On the headsets the
    /// displacement was 2.5 km; a build that applied it had its darts that
    /// far from the hands that pinched them.)
    func testARealityViewSceneIsTheSharedFrame() {
        let frame = SharedFrame()
        frame.declareSceneIsSharedFrame()
        XCTAssertTrue(frame.hasPlacement)
        XCTAssertEqual(frame.spaceDisplacement, matrix_identity_float4x4)
        var seat = simd_float4x4(simd_quatf(angle: 175 * .pi / 180, axis: SIMD3(0, 1, 0)))
        seat.columns.3 = SIMD4(-0.32, 0, 1.76, 1) // the system's pose of us over FaceTime
        frame.setSystemPose(seat)
        var head = matrix_identity_float4x4
        head.columns.3 = SIMD4(-0.30, 1.62, 1.80, 1) // ARKit's device pose: already in the scene's frame
        frame.updateDevicePose(head)
        let board = SIMD3<Float>(0, 1.73, -0.6)
        XCTAssertEqual(simd_distance(frame.toLocal(sharedPoint: board), board), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(frame.toLocal(sharedDirection: SIMD3(0, 0, 1)), SIMD3(0, 0, 1)), 0, accuracy: 1e-5)
        XCTAssertEqual(frame.sharedFromLocal, matrix_identity_float4x4, "the seat does not move a declared frame")
        frame.reset()
        XCTAssertTrue(frame.hasPlacement, "the scene is still the shared frame after a session")
        XCTAssertEqual(frame.toLocal(sharedPoint: board), board)
    }

    /// Two RealityView devices: what one publishes in its scene lands at the
    /// same coordinates in the other's.
    func testTwoRealityViewScenesShareOneFrame() async throws {
        let hub = LoopbackHub()
        let a = SharePlaySession(transport: hub.makeTransport(id: participantID(1)))
        let b = SharePlaySession(transport: hub.makeTransport(id: participantID(2)))
        a.frame.declareSceneIsSharedFrame()
        b.frame.declareSceneIsSharedFrame()
        a.startObserving()
        b.startObserving()
        _ = await a.start()
        try await waitUntil { a.state == .joined && b.state == .joined && a.participants.count == 2 && b.participants.count == 2 }
        try await waitUntil { b.frame.alignment(of: participantID(1)) == .systemDisplacement && a.frame.alignment(of: participantID(2)) == .systemDisplacement }
        let hand = SIMD3<Float>(0.46, 1.15, 1.92)
        XCTAssertEqual(simd_distance(b.frame.toLocal(point: hand, from: participantID(1)), hand), 0, accuracy: 1e-4)
        XCTAssertEqual(simd_distance(a.frame.toLocal(point: hand, from: participantID(2)), hand), 0, accuracy: 1e-4)
        a.leave()
        b.leave()
    }

    /// The frame's own maths for a displaced space (the Compositor Services
    /// path): a placement given maps shared content into the local frame.
    func testContentInTheSharedFrameLandsInTheLocalFrameByThePlacement() {
        let frame = SharedFrame()
        // No placement: the shared frame is the local one.
        XCTAssertEqual(frame.toLocal(sharedPoint: SIMD3(0, 1.73, 0)), SIMD3(0, 1.73, 0))
        XCTAssertEqual(frame.spaceDisplacement, matrix_identity_float4x4)

        // A placement 2 m ahead, turned 90°.
        var displacement = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        displacement.columns.3 = SIMD4(0, 0, -2, 1)
        frame.setImmersiveSpaceDisplacement(displacement)
        XCTAssertEqual(frame.spaceDisplacement, displacement)
        let bull = frame.toLocal(sharedPoint: SIMD3(0, 1.73, 0))
        XCTAssertEqual(bull.x, 0, accuracy: 1e-4)
        XCTAssertEqual(bull.y, 1.73, accuracy: 1e-4)
        XCTAssertEqual(bull.z, -2, accuracy: 1e-4)
        let facing = frame.toLocal(sharedDirection: SIMD3(0, 0, 1))
        XCTAssertEqual(facing.x, 1, accuracy: 1e-4, "+z of the shared frame is +x here after the quarter turn")
        XCTAssertEqual(facing.z, 0, accuracy: 1e-4)
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(0, 1.73, 0, 1)
        let local = frame.toLocal(sharedPose: pose)
        XCTAssertEqual(local.columns.3.z, -2, accuracy: 1e-4)

        // Identity: the space is back where it was, and the system pose decides.
        frame.setImmersiveSpaceDisplacement(matrix_identity_float4x4)
        XCTAssertEqual(frame.spaceDisplacement, matrix_identity_float4x4)
        XCTAssertFalse(frame.hasPlacement)
        var seat = matrix_identity_float4x4
        seat.columns.3 = SIMD4(0, 0, 2.37, 1) // we sit 2.37 m in front of the origin in the shared frame
        frame.setSystemPose(seat)
        var device = matrix_identity_float4x4
        device.columns.3 = SIMD4(1, 1.6, 1, 1) // standing here in our own room
        frame.updateDevicePose(device)
        XCTAssertTrue(frame.hasPlacement)
        let origin = frame.toLocal(sharedPoint: .zero)
        XCTAssertEqual(origin.x, 1, accuracy: 1e-4)
        XCTAssertEqual(origin.z, 1 - 2.37, accuracy: 1e-4, "the shared origin is 2.37 m ahead of where we stand")

        // A session's end voids a pose-based placement; the space's displacement
        // is the space's, and the view re-reads it when the session goes idle.
        frame.reset()
        XCTAssertFalse(frame.hasPlacement)
    }

    func testARowOfSeatsIsCentredAndEvenlySpaced() {
        for (offset, expected) in zip(SharePlaySpatialTemplate.rowOffsets(seats: 4, spacing: 0.6), [-0.9, -0.3, 0.3, 0.9]) {
            XCTAssertEqual(offset, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(SharePlaySpatialTemplate.rowOffsets(seats: 1, spacing: 0.6), [0])
        XCTAssertEqual(SharePlaySpatialTemplate.rowOffsets(seats: 3, spacing: 1), [-1, 0, 1])
        XCTAssertEqual(SharePlaySpatialTemplate.rowOffsets(seats: 0, spacing: 1), [])
        XCTAssertEqual(SharePlaySpatialTemplate.row(seats: 4, spacing: 0.6, distance: 2.37), .row(seats: 4, spacing: 0.6, distance: 2.37))
    }
}
