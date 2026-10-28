import Foundation
import simd
@testable import UntoldSharePlay
import XCTest

final class SharedFrameTests: XCTestCase {
    private let other = participantID(2)

    private func point(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        SharedFrame.transform(point: p, by: m)
    }

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    func testFallbackStageSeatsFaceUs() {
        let frame = SharedFrame()
        XCTAssertEqual(frame.alignment(of: other), .fallbackStage)
        // Their origin lands 2 m ahead, their forward (-Z) points back at us.
        assertClose(frame.toLocal(point: .zero, from: other), SIMD3(0, 0, -2))
        assertClose(frame.toLocal(direction: SIMD3(0, 0, -1), from: other), SIMD3(0, 0, 1))
        // Three seats: the middle one straight ahead, the others 0.8 m apart.
        frame.setSeat(0, count: 3, for: other)
        assertClose(frame.toLocal(point: .zero, from: other), SIMD3(-0.8, 0, -2))
        frame.setSeat(2, count: 3, for: other)
        assertClose(frame.toLocal(point: .zero, from: other), SIMD3(0.8, 0, -2))
        frame.fallbackStage = SharedFrame.FallbackStage(distance: 1, spacing: 0.5)
        assertClose(frame.toLocal(point: .zero, from: other), SIMD3(0.5, 0, -1))
        XCTAssertTrue(frame.summary(of: other).contains("seat 3 of 3"))
    }

    func testSystemPlacementsComposeOursWithTheirs() {
        let frame = SharedFrame()
        var localFromShared = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        localFromShared.columns.3 = SIMD4(1, 0, -3, 1)
        frame.setSystemDisplacement(localFromShared)
        XCTAssertTrue(frame.hasPlacement)
        assertClose(point(frame.localFromShared, .zero), SIMD3(1, 0, -3))
        assertClose(point(frame.sharedFromLocal * localFromShared, SIMD3(0.3, 1.6, -0.5)), SIMD3(0.3, 1.6, -0.5))
        XCTAssertTrue(frame.displacementSummary.contains("yaw"))
        XCTAssertEqual(frame.takeOutgoingPlacement(), frame.sharedFromLocal, "announced once")
        XCTAssertNil(frame.takeOutgoingPlacement())

        // Nearby, but their placement unknown: still the fallback.
        frame.setSharesSystemFrame(true, for: other)
        XCTAssertEqual(frame.alignment(of: other), .fallbackStage)
        XCTAssertTrue(frame.summary(of: other).contains("their placement unknown"))
        // Their placement: their local is the shared frame itself.
        frame.receivePlacement(sharedFromLocal: matrix_identity_float4x4, from: other)
        XCTAssertEqual(frame.alignment(of: other), .systemDisplacement)
        assertClose(frame.toLocal(point: .zero, from: other), SIMD3(1, 0, -3))
        // Their placement 2 m along shared +X: their origin lands there.
        var theirs = matrix_identity_float4x4
        theirs.columns.3 = SIMD4(2, 0, 0, 1)
        frame.receivePlacement(sharedFromLocal: theirs, from: other)
        assertClose(frame.toLocal(point: .zero, from: other), point(localFromShared, SIMD3(2, 0, 0)))
        frame.setSharesSystemFrame(false, for: other)
        XCTAssertEqual(frame.alignment(of: other), .fallbackStage)
        XCTAssertTrue(frame.summary(of: other).contains("not spatial, not nearby"))
    }

    func testFloorPoseKeepsPositionAndYawOnly() {
        // A head 1.6 m up, pitched down, facing +X.
        var head = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 1, 0)))
        head = head * simd_float4x4(simd_quatf(angle: 0.4, axis: SIMD3(1, 0, 0)))
        head.columns.3 = SIMD4(2, 1.6, -1, 1)
        let floor = SharedFrame.floorPose(head)
        assertClose(point(floor, .zero), SIMD3(2, 0, -1))
        assertClose(SharedFrame.transform(direction: SIMD3(0, 0, -1), by: floor), SIMD3(1, 0, 0), accuracy: 1e-3)
        assertClose(SharedFrame.transform(direction: SIMD3(0, 1, 0), by: floor), SIMD3(0, 1, 0))
    }

    func testSystemPosePairedOnTheFloorGivesThePlacement() {
        let frame = SharedFrame()
        XCTAssertFalse(frame.hasPlacement)
        // The system says we stand 2 m along shared -Z, facing shared +Z (back
        // at the origin); our device is 1.7 m up at our origin, facing our -Z.
        var systemPose = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)))
        systemPose.columns.3 = SIMD4(0, 0, -2, 1)
        var device = matrix_identity_float4x4
        device.columns.3 = SIMD4(0, 1.7, 0, 1)
        frame.setSystemPose(systemPose)
        XCTAssertFalse(frame.hasPlacement, "no device pose yet")
        frame.updateDevicePose(device)
        XCTAssertTrue(frame.hasPlacement)
        // Our origin, in the shared frame, is where the system put us; the
        // head's height never enters it.
        assertClose(point(frame.sharedFromLocal, .zero), SIMD3(0, 0, -2))
        assertClose(SharedFrame.transform(direction: SIMD3(0, 0, -1), by: frame.sharedFromLocal), SIMD3(0, 0, 1), accuracy: 1e-3)
        assertClose(point(frame.sharedFromLocal, SIMD3(0, 1.7, 0)), SIMD3(0, 1.7, -2))
        XCTAssertNotNil(frame.takeOutgoingPlacement())
        // A head that only bobbed: no new placement; a step: a new one.
        var bobbed = device
        bobbed.columns.3 = SIMD4(0.005, 1.65, 0, 1)
        frame.updateDevicePose(bobbed)
        XCTAssertNil(frame.takeOutgoingPlacement())
        var stepped = device
        stepped.columns.3 = SIMD4(0.5, 1.7, 0, 1)
        frame.updateDevicePose(stepped)
        XCTAssertNotNil(frame.takeOutgoingPlacement(), "the pairing follows the pose")
        // The pose going away clears a pose-based placement; the space's own
        // displacement wins once it exists and outlives the session.
        frame.setSystemPose(nil)
        XCTAssertFalse(frame.hasPlacement)
        frame.setSystemDisplacement(matrix_identity_float4x4)
        frame.setSystemPose(systemPose)
        XCTAssertEqual(frame.sharedFromLocal, matrix_identity_float4x4)
        frame.reset()
        XCTAssertTrue(frame.hasPlacement)
    }

    func testSharedAnchorWinsOverDisplacementAndSurvivesTrackingLoss() {
        let frame = SharedFrame()
        frame.setSharesSystemFrame(true, for: other)
        frame.setSystemDisplacement(matrix_identity_float4x4)
        frame.receivePlacement(sharedFromLocal: matrix_identity_float4x4, from: other)
        var localFromOther = matrix_identity_float4x4
        localFromOther.columns.3 = SIMD4(2, 0, 0, 1)
        frame.setAnchor(localFromParticipant: localFromOther, tracked: true, summary: "shared anchor tracked", for: other)
        XCTAssertEqual(frame.alignment(of: other), .sharedAnchor)
        assertClose(frame.toLocal(point: SIMD3(0, 1, 0), from: other), SIMD3(2, 1, 0))
        frame.setAnchor(localFromParticipant: localFromOther, tracked: false, summary: "shared anchor NOT tracked", for: other)
        XCTAssertEqual(frame.alignment(of: other), .sharedAnchor)
        XCTAssertTrue(frame.summary(of: other).contains("NOT tracked"))
        frame.setAnchor(localFromParticipant: nil, tracked: false, summary: "", for: other)
        XCTAssertEqual(frame.alignment(of: other), .systemDisplacement)
    }

    func testYawAlignedFrameTranslationOnly() throws {
        let solved = try XCTUnwrap(SharedFrame.yawAlignedFrame(
            localPoint: SIMD3(1, 1, -1), localHeading: SIMD3(0, 0, -1),
            remotePoint: SIMD3(0, 1, 0), remoteHeading: SIMD3(0, 0, -1)
        ))
        XCTAssertEqual(solved.yawDegrees, 0, accuracy: 1e-3)
        assertClose(point(solved.localFromRemote, SIMD3(0, 1, 0)), SIMD3(1, 1, -1))
    }

    func testYawAlignedFrameQuarterTurn() throws {
        // The remote frame is rotated 90° about Y relative to ours.
        let solved = try XCTUnwrap(SharedFrame.yawAlignedFrame(
            localPoint: SIMD3(0, 1, -2), localHeading: SIMD3(0, 0, -1),
            remotePoint: SIMD3(0, 1, -2), remoteHeading: SIMD3(1, 0, 0)
        ))
        XCTAssertEqual(abs(solved.yawDegrees), 90, accuracy: 1e-2)
        assertClose(point(solved.localFromRemote, SIMD3(0, 1, -2)), SIMD3(0, 1, -2))
        assertClose(SharedFrame.transform(direction: SIMD3(1, 0, 0), by: solved.localFromRemote), SIMD3(0, 0, -1))
    }

    func testYawAlignedFrameRejectsVerticalHeadings() {
        XCTAssertNil(SharedFrame.yawAlignedFrame(
            localPoint: .zero, localHeading: SIMD3(0, 1, 0.1),
            remotePoint: .zero, remoteHeading: SIMD3(0, 0, -1)
        ))
    }

    func testCalibrationInstallsManualAndQueuesTheInverse() {
        let frame = SharedFrame()
        frame.setSharesSystemFrame(true, for: other)
        let outcome = frame.calibrate(
            with: other,
            localPoint: SIMD3(1, 1, -1), localHeading: SIMD3(0, 0, -1),
            remotePoint: SIMD3(0, 1, 0), remoteHeading: SIMD3(0, 0, -1)
        )
        guard case let .solved(yaw, offset) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(yaw, 0, accuracy: 1e-3)
        assertClose(offset, SIMD3(1, 0, -1))
        XCTAssertEqual(frame.alignment(of: other), .manual)
        assertClose(frame.toLocal(point: SIMD3(0, 1, 0), from: other), SIMD3(1, 1, -1))

        let syncs = frame.takeOutgoingSyncs(now: 0)
        XCTAssertEqual(syncs.count, 1)
        XCTAssertEqual(syncs[0].participant, other)
        // The inverse maps our point back into theirs.
        assertClose(point(syncs[0].receiverFromSender, SIMD3(1, 1, -1)), SIMD3(0, 1, 0))
        XCTAssertTrue(frame.takeOutgoingSyncs(now: 0).isEmpty)

        XCTAssertEqual(frame.calibrate(with: other, localPoint: .zero, localHeading: SIMD3(0, 1, 0), remotePoint: .zero, remoteHeading: SIMD3(0, 0, -1)), .failed("hold the headings level"))
    }

    func testNudgeRunsAlongTheHeadingAndSettles() {
        let frame = SharedFrame()
        _ = frame.calibrate(with: other, localPoint: .zero, localHeading: SIMD3(0, 0, -1), remotePoint: .zero, remoteHeading: SIMD3(0, 0, -1))
        XCTAssertTrue(frame.takeOutgoingSyncs(now: 100).count == 1)
        frame.setNudge(SIMD2(0.1, 0.5), for: other) // 0.1 m right, 0.5 m forward
        XCTAssertEqual(frame.nudge(for: other), SIMD2(0.1, 0.5))
        // Forward is -Z, right is +X.
        assertClose(frame.toLocal(point: .zero, from: other), SIMD3(0.1, 0, -0.5))
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(frame.takeOutgoingSyncs(now: now).isEmpty, "not settled yet")
        let settled = frame.takeOutgoingSyncs(now: now + 1)
        XCTAssertEqual(settled.count, 1)
        assertClose(point(settled[0].receiverFromSender, SIMD3(0.1, 0, -0.5)), .zero)
        XCTAssertTrue(frame.takeOutgoingSyncs(now: now + 2).isEmpty)
        // The heading only follows the player while the nudge is zero.
        frame.setNudgeHeading(SIMD3(1, 0, 0), for: other)
        assertClose(frame.toLocal(point: .zero, from: other), SIMD3(0.1, 0, -0.5))
        XCTAssertEqual(frame.nudge(for: participantID(9)), .zero, "no manual solution, no nudge")
    }

    func testReceivedSyncOverridesAnchorAndForgetClears() {
        let frame = SharedFrame()
        var localFromOther = matrix_identity_float4x4
        localFromOther.columns.3 = SIMD4(2, 0, 0, 1)
        frame.setAnchor(localFromParticipant: localFromOther, tracked: true, summary: "anchor", for: other)
        var received = matrix_identity_float4x4
        received.columns.3 = SIMD4(0, 0, -1, 1)
        frame.receiveManual(localFromParticipant: received, from: other)
        XCTAssertEqual(frame.alignment(of: other), .manual)
        assertClose(frame.toLocal(point: .zero, from: other), SIMD3(0, 0, -1))
        XCTAssertTrue(frame.summary(of: other).contains("synced by the other side"))
        frame.forget(other)
        XCTAssertEqual(frame.alignment(of: other), .fallbackStage)
    }

    func testCalibrationToAMarkUsesTheMarkedPoseRaw() {
        let frame = SharedFrame()
        XCTAssertEqual(frame.calibrate(with: other, localPoint: .zero, localHeading: SIMD3(0, 0, -1)), .failed("no mark from the other side yet"))
        // The other player marked their spot: 1.6 m up at their origin, facing their -Z.
        var mark = matrix_identity_float4x4
        mark.columns.3 = SIMD4(0, 1.6, 0, 1)
        frame.receiveMark(mark, from: other)
        XCTAssertEqual(frame.mark(from: other), mark)
        // We stand on that spot: in our frame it is 2 m ahead, same heading.
        let outcome = frame.calibrate(with: other, localPoint: SIMD3(0, 1.6, -2), localHeading: SIMD3(0, 0, -1))
        guard case let .solved(yaw, offset) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(yaw, 0, accuracy: 1e-3)
        assertClose(offset, SIMD3(0, 0, -2))
        assertClose(frame.toLocal(point: SIMD3(0, 1.6, 0), from: other), SIMD3(0, 1.6, -2))
        XCTAssertEqual(frame.takeOutgoingSyncs(now: 0).count, 1)
        // Our own mark goes out once, in the shared frame.
        XCTAssertNil(frame.takeOutgoingMark())
        var head = matrix_identity_float4x4
        head.columns.3 = SIMD4(1, 1.6, -1, 1)
        frame.publishMark(localPose: head)
        XCTAssertEqual(frame.takeOutgoingMark(), head, "identity displacement: the mark is the local pose")
        XCTAssertNil(frame.takeOutgoingMark())
        frame.forget(other)
        XCTAssertNil(frame.mark(from: other))
    }

    func testCodableMatrixRoundTrip() throws {
        var matrix = simd_float4x4(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)))
        matrix.columns.3 = SIMD4(1, 2, 3, 1)
        let data = try JSONEncoder().encode(SharePlayMatrix(matrix))
        XCTAssertEqual(try JSONDecoder().decode(SharePlayMatrix.self, from: data).matrix, matrix)
        XCTAssertEqual(SharePlayMatrix(columns: []).matrix, matrix_identity_float4x4)
    }
}

extension SharePlayMatrix {
    init(columns: [SIMD4<Float>]) {
        self.init(matrix_identity_float4x4)
        self.columns = columns
    }
}
