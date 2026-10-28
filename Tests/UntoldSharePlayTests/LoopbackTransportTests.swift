import Foundation
@testable import UntoldSharePlay
import XCTest

@MainActor
final class LoopbackTransportTests: XCTestCase {
    func testStartJoinSendLeaveEnd() async throws {
        let hub = LoopbackHub()
        let a = hub.makeTransport(id: participantID(1), nearby: true)
        let b = hub.makeTransport(id: participantID(2))
        var sessionsA = a.sessions().makeAsyncIterator()
        var sessionsB = b.sessions().makeAsyncIterator()

        let started = await a.start()
        XCTAssertEqual(started, .started)
        XCTAssertTrue(hub.isSessionActive)
        let firstA = await sessionsA.next()
        let firstB = await sessionsB.next()
        let sessionA = try XCTUnwrap(firstA)
        let sessionB = try XCTUnwrap(firstB)
        XCTAssertEqual(sessionA.localParticipantID, participantID(1))
        XCTAssertEqual(sessionB.localParticipantID, participantID(2))

        var statesA = sessionA.states.makeAsyncIterator()
        var participantsA = sessionA.participants.makeAsyncIterator()
        var participantsB = sessionB.participants.makeAsyncIterator()
        let reliableA = sessionA.makeChannel(delivery: .reliable)
        let reliableB = sessionB.makeChannel(delivery: .reliable)
        var incomingB = reliableB.incoming.makeAsyncIterator()

        let waiting = await statesA.next()
        XCTAssertEqual(waiting, .waiting)
        sessionA.join()
        let joined = await statesA.next()
        XCTAssertEqual(joined, .joined)
        let alone = await participantsA.next()
        XCTAssertEqual(alone, [SharePlayTransportParticipant(id: participantID(1), isNearby: true)])

        // Nobody else joined: nothing is delivered, and nothing comes back to the sender.
        try await reliableA.send(Data([1]), to: .all)
        sessionB.join()
        let afterJoinA = await participantsA.next()
        XCTAssertEqual(afterJoinA?.map(\.id).sorted { $0.uuidString < $1.uuidString }, [participantID(1), participantID(2)])
        XCTAssertEqual(afterJoinA?.first { $0.id == participantID(1) }?.isNearby, true)
        let afterJoinB = await participantsB.next()
        XCTAssertEqual(afterJoinB?.count, 2)

        try await reliableA.send(Data([2]), to: .all)
        let received = await incomingB.next()
        XCTAssertEqual(received?.data, Data([2]))
        XCTAssertEqual(received?.sender, participantID(1))

        // `.only` with a stranger's id delivers nothing; with B's id, delivers.
        try await reliableA.send(Data([3]), to: .only([participantID(9)]))
        try await reliableA.send(Data([4]), to: .only([participantID(2)]))
        let targeted = await incomingB.next()
        XCTAssertEqual(targeted?.data, Data([4]))

        sessionB.leave()
        let afterLeave = await participantsA.next()
        XCTAssertEqual(afterLeave?.map(\.id), [participantID(1)])

        sessionA.end()
        let ended = await statesA.next()
        XCTAssertEqual(ended, .invalidated("ended"))
        let finished = await statesA.next()
        XCTAssertNil(finished)
        XCTAssertFalse(hub.isSessionActive)
    }

    func testLastOneLeavingEndsTheSession() async throws {
        let hub = LoopbackHub()
        let a = hub.makeTransport(id: participantID(1))
        var sessionsA = a.sessions().makeAsyncIterator()
        _ = await a.start()
        let maybeA = await sessionsA.next()
        let sessionA = try XCTUnwrap(maybeA)
        var statesA = sessionA.states.makeAsyncIterator()
        sessionA.join()
        _ = await statesA.next() // waiting
        _ = await statesA.next() // joined
        sessionA.leave()
        let left = await statesA.next()
        XCTAssertEqual(left, .invalidated("left"))
        XCTAssertFalse(hub.isSessionActive)
    }

    func testReorderOnTheUnreliablePath() async throws {
        var options = LoopbackHub.Options()
        options.reorderUnreliable = true
        let hub = LoopbackHub(options: options)
        let a = hub.makeTransport(id: participantID(1))
        let b = hub.makeTransport(id: participantID(2))
        var sessionsA = a.sessions().makeAsyncIterator()
        var sessionsB = b.sessions().makeAsyncIterator()
        _ = await a.start()
        let maybeA = await sessionsA.next()
        let maybeB = await sessionsB.next()
        let sessionA = try XCTUnwrap(maybeA)
        let sessionB = try XCTUnwrap(maybeB)
        let unreliableA = sessionA.makeChannel(delivery: .unreliable)
        let unreliableB = sessionB.makeChannel(delivery: .unreliable)
        var incomingB = unreliableB.incoming.makeAsyncIterator()
        sessionA.join()
        sessionB.join()

        try await unreliableA.send(Data([1]), to: .all) // held back
        try await unreliableA.send(Data([2]), to: .all) // delivered, then the held one
        let first = await incomingB.next()
        let second = await incomingB.next()
        XCTAssertEqual(first?.data, Data([2]))
        XCTAssertEqual(second?.data, Data([1]))
    }

    func testLossDropsUnreliableFramesOnly() async throws {
        var lossy = LoopbackHub.Options()
        lossy.unreliableLoss = 1
        let hub = LoopbackHub(options: lossy)
        let c = hub.makeTransport(id: participantID(3))
        let d = hub.makeTransport(id: participantID(4))
        var sessionsC = c.sessions().makeAsyncIterator()
        var sessionsD = d.sessions().makeAsyncIterator()
        _ = await c.start()
        let maybeC = await sessionsC.next()
        let maybeD = await sessionsD.next()
        let sessionC = try XCTUnwrap(maybeC)
        let sessionD = try XCTUnwrap(maybeD)
        let unreliableC = sessionC.makeChannel(delivery: .unreliable)
        let reliableC = sessionC.makeChannel(delivery: .reliable)
        _ = sessionD.makeChannel(delivery: .unreliable)
        let reliableD = sessionD.makeChannel(delivery: .reliable)
        var reliableIncomingD = reliableD.incoming.makeAsyncIterator()
        sessionC.join()
        sessionD.join()
        try await unreliableC.send(Data([1]), to: .all) // lost
        try await reliableC.send(Data([2]), to: .all) // arrives
        let received = await reliableIncomingD.next()
        XCTAssertEqual(received?.data, Data([2]))
    }

    func testSessionsDeliveredToATransportThatSubscribesLate() async {
        let hub = LoopbackHub()
        let a = hub.makeTransport(id: participantID(1))
        let b = hub.makeTransport(id: participantID(2))
        var sessionsA = a.sessions().makeAsyncIterator()
        _ = await a.start()
        _ = await sessionsA.next()
        // B subscribes after the session started: it still gets it.
        var sessionsB = b.sessions().makeAsyncIterator()
        let sessionB = await sessionsB.next()
        XCTAssertEqual(sessionB?.localParticipantID, participantID(2))
    }
}
