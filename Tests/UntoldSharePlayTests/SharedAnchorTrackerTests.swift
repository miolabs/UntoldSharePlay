import Foundation
import simd
@testable import UntoldSharePlay
import XCTest

/// A world-tracking runtime that records what the tracker asks and lets the
/// test report anchors.
final class FakeAnchorHost: SharePlayWorldAnchorHost, @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (SharePlayAnchorUpdate) -> Void] = [:]
    private(set) var added: [simd_float4x4] = []
    private(set) var removed: [UUID] = []
    var nextHandle = UUID()

    func addSharedWorldAnchor(localFromAnchor: simd_float4x4) -> UUID? {
        lock.withLock {
            added.append(localFromAnchor)
            return nextHandle
        }
    }

    func removeWorldAnchor(_ handle: UUID) {
        lock.withLock { removed.append(handle) }
    }

    func addWorldAnchorObserver(_ handler: @escaping @Sendable (SharePlayAnchorUpdate) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return id
    }

    func removeWorldAnchorObserver(_ id: UUID) {
        lock.withLock { observers[id] = nil }
    }

    var observerCount: Int {
        lock.withLock { observers.count }
    }

    func report(_ update: SharePlayAnchorUpdate) {
        let handlers = lock.withLock { Array(observers.values) }
        for handler in handlers { handler(update) }
    }
}

final class SharedAnchorTrackerTests: XCTestCase {
    private let a = participantID(1), b = participantID(2), c = participantID(3)

    private func update(_ id: UUID, x: Float, tracked: Bool = true, shared: Bool = true, own: Bool = false, event: SharePlayAnchorUpdate.Event = .added) -> SharePlayAnchorUpdate {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(x, 0, 0, 1)
        return SharePlayAnchorUpdate(id: id, localFromAnchor: pose, isTracked: tracked, isShared: shared, isOwn: own, event: event)
    }

    func testOwnAnchorFollowsNearbyParticipantsAndIsAnnounced() {
        let frame = SharedFrame()
        let tracker = SharedAnchorTracker(frame: frame)
        let host = FakeAnchorHost()
        tracker.attach(host)
        XCTAssertTrue(tracker.isAttached)
        XCTAssertEqual(host.observerCount, 1)
        XCTAssertTrue(host.added.isEmpty, "nobody nearby yet")

        tracker.update(nearby: [b], sessionActive: true)
        XCTAssertTrue(tracker.wantsOwnAnchor)
        XCTAssertEqual(host.added.count, 1)
        XCTAssertEqual(host.added[0], matrix_identity_float4x4)
        XCTAssertNil(tracker.ownAnchorID)
        XCTAssertTrue(tracker.takeOutgoingAnnouncements().isEmpty)

        let anchorID = UUID()
        host.report(update(anchorID, x: 0, own: true))
        XCTAssertEqual(tracker.ownAnchorID, anchorID)
        let announcements = tracker.takeOutgoingAnnouncements()
        XCTAssertEqual(announcements.count, 1)
        XCTAssertEqual(announcements[0].message, .sharedAnchor(id: anchorID))
        XCTAssertEqual(announcements[0].recipients, .all)
        host.report(update(anchorID, x: 0, own: true, event: .updated))
        XCTAssertTrue(tracker.takeOutgoingAnnouncements().isEmpty, "announced once")

        // A newcomer is told too.
        tracker.participantJoined(c)
        XCTAssertEqual(tracker.takeOutgoingAnnouncements().first?.recipients, .only([c]))

        // Nobody nearby: the anchor goes, the others are told.
        tracker.update(nearby: [], sessionActive: true)
        XCTAssertEqual(host.removed, [host.nextHandle])
        XCTAssertNil(tracker.ownAnchorID)
        XCTAssertEqual(tracker.takeOutgoingAnnouncements().first?.message, .sharedAnchorRemoved)
        tracker.detach()
        XCTAssertEqual(host.observerCount, 0)
    }

    func testRemoteAnchorIsAttributedByAnnouncementOrBySingleNearby() {
        let frame = SharedFrame()
        let tracker = SharedAnchorTracker(frame: frame)
        let host = FakeAnchorHost()
        tracker.attach(host)
        tracker.update(nearby: [b, c], sessionActive: true)

        // Two nearby participants: an unannounced anchor waits.
        let anchorB = UUID()
        host.report(update(anchorB, x: 2))
        XCTAssertEqual(frame.alignment(of: b), .fallbackStage)
        tracker.receiveAnnouncement(anchorID: anchorB, from: b)
        XCTAssertEqual(frame.alignment(of: b), .sharedAnchor)
        XCTAssertEqual(frame.toLocal(point: .zero, from: b), SIMD3(2, 0, 0))
        XCTAssertEqual(frame.alignment(of: c), .fallbackStage)

        // The alignment is handed to its owner as a sync: once, then only when it moved.
        var syncs = frame.takeOutgoingSyncs(now: 0)
        XCTAssertEqual(syncs.count, 1)
        XCTAssertEqual(syncs[0].participant, b)
        XCTAssertEqual(SharedFrame.transform(point: SIMD3(2, 0, 0), by: syncs[0].receiverFromSender), .zero, "their local-from-us is the inverse")
        host.report(update(anchorB, x: 2.001, event: .updated))
        XCTAssertTrue(frame.takeOutgoingSyncs(now: 0).isEmpty, "a millimetre is not a move")

        // Updates keep flowing to the owner; a tracking loss keeps the pose.
        host.report(update(anchorB, x: 2.5, event: .updated))
        syncs = frame.takeOutgoingSyncs(now: 0)
        XCTAssertTrue(syncs.isEmpty, "throttled to once a second")
        XCTAssertEqual(frame.toLocal(point: .zero, from: b), SIMD3(2.5, 0, 0))
        host.report(update(anchorB, x: 2.5, tracked: false, event: .updated))
        XCTAssertTrue(frame.summary(of: b).contains("NOT tracked"))
        host.report(update(anchorB, x: 2.5, event: .removed))
        XCTAssertEqual(frame.alignment(of: b), .fallbackStage)

        // One nearby participant: theirs without an announcement.
        tracker.update(nearby: [c], sessionActive: true)
        host.report(update(UUID(), x: -1))
        XCTAssertEqual(frame.alignment(of: c), .sharedAnchor)
        XCTAssertEqual(frame.toLocal(point: .zero, from: c), SIMD3(-1, 0, 0))

        // Not shared, or own: ignored for others.
        host.report(update(UUID(), x: 9, shared: false))
        XCTAssertEqual(frame.toLocal(point: .zero, from: c), SIMD3(-1, 0, 0))

        tracker.receiveRemoval(from: c)
        XCTAssertEqual(frame.alignment(of: c), .fallbackStage)
    }

    func testResetRemovesOwnAnchorAndKeepsTheHost() {
        let frame = SharedFrame()
        let tracker = SharedAnchorTracker(frame: frame)
        let host = FakeAnchorHost()
        tracker.attach(host)
        tracker.update(nearby: [b], sessionActive: true)
        XCTAssertEqual(host.added.count, 1)
        tracker.reset()
        XCTAssertEqual(host.removed.count, 1)
        XCTAssertTrue(tracker.isAttached)
        XCTAssertFalse(tracker.wantsOwnAnchor)
        XCTAssertEqual(tracker.summary, "no nearby participant")
        // A host attached later gets the anchor at once when one is wanted.
        let tracker2 = SharedAnchorTracker(frame: SharedFrame())
        tracker2.update(nearby: [b], sessionActive: true)
        XCTAssertEqual(tracker2.summary, "no anchor host")
        let host2 = FakeAnchorHost()
        tracker2.attach(host2)
        XCTAssertEqual(host2.added.count, 1)
    }
}
