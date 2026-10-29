import Foundation
@testable import UntoldSharePlay
import XCTest

/// The recipes of docs/Recipes.md that run without a headset, as tests: the
/// two devices are two sessions in one process over the loopback transport.
/// Keep them in step with the document.
@MainActor
final class RecipesTests: XCTestCase {
    struct Score: Codable, Sendable, Equatable {
        var points: Int
    }

    enum Shout: Codable, Sendable, Equatable {
        case wave
        case snapshot(points: Int)
    }

    private func makePair(hostElection: HostElection = .none, options: LoopbackHub.Options = LoopbackHub.Options())
        -> (a: SharePlaySession, b: SharePlaySession)
    {
        let hub = LoopbackHub(options: options)
        var configuration = SharePlaySession.Configuration()
        configuration.stateRate = 200
        configuration.hostElection = hostElection
        let a = SharePlaySession(transport: hub.makeTransport(id: participantID(1)), configuration: configuration)
        let b = SharePlaySession(transport: hub.makeTransport(id: participantID(2)), configuration: configuration)
        a.startObserving()
        b.startObserving()
        return (a, b)
    }

    private func join(_ a: SharePlaySession, _ b: SharePlaySession) async throws {
        let result = await a.start()
        XCTAssertEqual(result, .started)
        try await waitUntil { a.state == .joined && b.state == .joined && a.others.count == 1 && b.others.count == 1 }
    }

    /// Recipe 1.
    func testShareAValueEveryoneReads() async throws {
        let (a, b) = makePair()
        let scoresA = a.stateChannel(Score.self)
        let scoresB = b.stateChannel(Score.self)
        try await join(a, b)

        scoresA.publish(Score(points: 3))
        scoresA.publish(Score(points: 4)) // before the pump ran: the earlier one is dropped, the latest wins
        try await waitUntil { scoresB.latest(from: participantID(1))?.message == Score(points: 4) }
        let received = try XCTUnwrap(scoresB.latest(from: participantID(1)))
        XCTAssertLessThan(received.age, 1)
        XCTAssertEqual(scoresB.latestAll().count, 1)
        XCTAssertNil(scoresA.latest(from: participantID(1)), "a sender never receives its own value")
        a.leave()
        b.leave()
    }

    /// Recipe 2.
    func testTellEveryoneSomethingHappened() async throws {
        let (a, b) = makePair()
        let shoutsA = a.eventChannel(Shout.self)
        let shoutsB = b.eventChannel(Shout.self)
        try await join(a, b)

        shoutsA.send(.wave)
        shoutsA.send(.snapshot(points: 1))
        shoutsA.send(.snapshot(points: 2), to: .only([participantID(2)]))
        shoutsA.send(.snapshot(points: 3), to: .only([participantID(9)])) // nobody: dropped
        var got: [Shout] = []
        try await waitUntil {
            got += shoutsB.drain().map(\.message)
            return got.count == 3
        }
        XCTAssertEqual(got, [.wave, .snapshot(points: 1), .snapshot(points: 2)], "in order, to everyone or to one")
        XCTAssertTrue(shoutsB.drain().isEmpty, "a drain empties the inbox")
        a.leave()
        b.leave()
    }

    /// Recipe 3.
    func testGiveTheNewcomerTheCurrentState() async throws {
        let (a, b) = makePair()
        let shoutsA = a.eventChannel(Shout.self)
        let shoutsB = b.eventChannel(Shout.self)
        let currentPoints = 7
        a.addEventHandler { event in
            if case let .participantJoined(id) = event {
                shoutsA.send(.snapshot(points: currentPoints), to: .only([id]))
            }
        }
        try await join(a, b)

        var got: [Shout] = []
        try await waitUntil {
            got += shoutsB.drain().map(\.message)
            return !got.isEmpty
        }
        XCTAssertEqual(got, [.snapshot(points: 7)])
        a.leave()
        b.leave()
    }

    /// Recipe 4.
    func testPickOneDeviceToDecide() async throws {
        let (a, b) = makePair(hostElection: .lowestParticipantID)
        try await join(a, b)
        try await waitUntil { a.hostID != nil && b.hostID != nil }
        XCTAssertEqual(a.hostID, b.hostID, "the same answer on every device")
        XCTAssertEqual(a.isHost, a.localParticipantID == a.hostID)
        XCTAssertNotEqual(a.isHost, b.isHost, "on exactly one device")

        // The host leaves: the other device is the host now.
        let host = a.isHost ? a : b
        let other = a.isHost ? b : a
        host.leave()
        try await waitUntil { other.others.isEmpty && other.isHost }
        other.leave()
    }

    /// Recipe 8.
    func testTryItOnAMacWithALossyLink() async throws {
        var options = LoopbackHub.Options()
        options.unreliableLoss = 0.5
        options.reorderUnreliable = true
        options.delay = 0.005
        options.seed = 7
        let (a, b) = makePair(options: options)
        let scoresA = a.stateChannel(Score.self)
        let scoresB = b.stateChannel(Score.self)
        try await join(a, b)

        // Half the frames are lost and the rest arrive out of order: the
        // latest value still wins, and never goes backwards.
        var sent = 0
        var seen: [Int] = []
        try await waitUntil {
            sent += 1
            scoresA.publish(Score(points: sent))
            if let points = scoresB.latest(from: participantID(1))?.message.points { seen.append(points) }
            return (seen.last ?? 0) >= 20
        }
        XCTAssertEqual(seen, seen.sorted(), "stale frames are dropped by sequence")
        XCTAssertLessThan(Set(seen).count, sent, "some frames were lost on the way")
        a.leave()
        b.leave()
    }
}
