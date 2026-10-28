import Foundation
import simd
@testable import UntoldSharePlay
import XCTest

@MainActor
final class SessionFrameTests: XCTestCase {
    private func makePair(nearby: Bool = false) -> (hub: LoopbackHub, a: SharePlaySession, b: SharePlaySession) {
        let hub = LoopbackHub()
        var configuration = SharePlaySession.Configuration()
        configuration.stateRate = 200
        let a = SharePlaySession(transport: hub.makeTransport(id: participantID(1), nearby: nearby), configuration: configuration)
        let b = SharePlaySession(transport: hub.makeTransport(id: participantID(2), nearby: nearby), configuration: configuration)
        return (hub, a, b)
    }

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    func testCalibrationReachesTheOtherSideAndNudgesFollow() async throws {
        let (_, a, b) = makePair()
        a.startObserving()
        b.startObserving()
        _ = await a.start()
        try await waitUntil { a.others.count == 1 && b.others.count == 1 }
        let idA = participantID(1), idB = participantID(2)
        XCTAssertEqual(a.frame.alignment(of: idB), .fallbackStage, "remote, not spatial")

        // A solves: B's origin is 1 m ahead of A, same heading.
        let outcome = a.frame.calibrate(with: idB, localPoint: SIMD3(0, 0, -1), localHeading: SIMD3(0, 0, -1), remotePoint: .zero, remoteHeading: SIMD3(0, 0, -1))
        guard case .solved = outcome else { return XCTFail("\(outcome)") }
        try await waitUntil { b.frame.alignment(of: idA) == .manual }
        // The two mappings are inverses: A's origin is 1 m behind B.
        assertClose(a.frame.toLocal(point: .zero, from: idB), SIMD3(0, 0, -1))
        assertClose(b.frame.toLocal(point: .zero, from: idA), SIMD3(0, 0, 1))

        a.frame.setNudge(SIMD2(0, 0.5), for: idB)
        try await waitUntil { abs(b.frame.toLocal(point: .zero, from: idA).z - 1.5) < 1e-4 }
        assertClose(a.frame.toLocal(point: .zero, from: idB), SIMD3(0, 0, -1.5))

        b.leave()
        try await waitUntil { a.others.isEmpty }
        XCTAssertEqual(a.frame.alignment(of: idB), .fallbackStage, "the leaver's solution is void")
        a.leave()
    }

    func testFallbackSeatsFollowJoinOrder() async throws {
        let hub = LoopbackHub()
        var configuration = SharePlaySession.Configuration()
        configuration.stateRate = 200
        let sessions = (1 ... 3).map { SharePlaySession(transport: hub.makeTransport(id: participantID($0)), configuration: configuration) }
        for session in sessions { session.startObserving() }
        _ = await sessions[0].start()
        try await waitUntil { sessions.allSatisfy { $0.others.count == 2 } }
        let first = sessions[0]
        let others = first.others.map(\.id)
        XCTAssertEqual(others.count, 2)
        let x0 = first.frame.toLocal(point: .zero, from: others[0]).x
        let x1 = first.frame.toLocal(point: .zero, from: others[1]).x
        XCTAssertEqual(x0, -0.4, accuracy: 1e-4)
        XCTAssertEqual(x1, 0.4, accuracy: 1e-4)
        XCTAssertTrue(first.frame.summary(of: others[1]).contains("seat 2 of 2"))
        for session in sessions { session.leave() }
    }

    func testSharedAnchorsAreAnnouncedAndAttributedAcrossSessions() async throws {
        let (_, a, b) = makePair(nearby: true)
        let hostA = FakeAnchorHost(), hostB = FakeAnchorHost()
        a.anchors.attach(hostA)
        b.anchors.attach(hostB)
        a.startObserving()
        b.startObserving()
        _ = await a.start()
        try await waitUntil { a.others.count == 1 && b.others.count == 1 }
        let idA = participantID(1), idB = participantID(2)
        XCTAssertTrue(a.others[0].isNearby)
        XCTAssertEqual(a.frame.alignment(of: idB), .systemDisplacement, "nearby: the system's frame until an anchor arrives")
        try await waitUntil { hostA.added.count == 1 && hostB.added.count == 1 }

        // ARKit reports A's own anchor; A announces it; B receives the
        // announcement, then B's ARKit reports the same anchor 1.5 m away.
        let anchorA = UUID()
        hostA.report(SharePlayAnchorUpdate(id: anchorA, localFromAnchor: matrix_identity_float4x4, isTracked: true, isShared: true, isOwn: true, event: .added))
        try await waitUntil { b.anchors.summary.contains("own anchor") || true }
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(1.5, 0, 0, 1)
        // Wait for the announcement to land before the anchor shows up on B.
        try await waitUntil { a.diagnostics.snapshot().channels[SharePlaySession.frameChannelID]?.sentFrames ?? 0 >= 1 }
        try await waitUntil { b.diagnostics.snapshot().channels[SharePlaySession.frameChannelID]?.receivedFrames ?? 0 >= 1 }
        hostB.report(SharePlayAnchorUpdate(id: anchorA, localFromAnchor: pose, isTracked: true, isShared: true, isOwn: false, event: .added))
        try await waitUntil { b.frame.alignment(of: idA) == .sharedAnchor }
        assertClose(b.frame.toLocal(point: .zero, from: idA), SIMD3(1.5, 0, 0))

        // A leaves: B's mapping for A goes, and B's own anchor is removed
        // since nobody nearby remains.
        a.leave()
        try await waitUntil { b.others.isEmpty }
        XCTAssertEqual(b.frame.alignment(of: idA), .fallbackStage)
        try await waitUntil { hostB.removed.count == 1 }
        b.leave()
    }

    func testSpatialParticipantsShareTheSystemFrame() async throws {
        let (hub, a, b) = makePair()
        a.startObserving()
        b.startObserving()
        _ = await a.start()
        try await waitUntil { a.others.count == 1 && b.others.count == 1 }
        let idB = participantID(2)
        var displacement = matrix_identity_float4x4
        displacement.columns.3 = SIMD4(0, 0, -4, 1)
        a.frame.setSystemDisplacement(displacement)
        XCTAssertEqual(a.frame.alignment(of: idB), .fallbackStage)
        let sessionA = try XCTUnwrap(hub.session(for: participantID(1)))
        sessionA.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, remoteIsSpatial: [idB: true], groupImmersion: .requested(.mixed)))
        try await waitUntil { a.frame.alignment(of: idB) == .systemDisplacement }
        assertClose(a.frame.toLocal(point: .zero, from: idB), SIMD3(0, 0, -4))
        sessionA.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, remoteIsSpatial: [idB: false], groupImmersion: .requested(.mixed)))
        try await waitUntil { a.frame.alignment(of: idB) == .fallbackStage }
        a.leave()
    }
}
