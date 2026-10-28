import Foundation
@testable import UntoldSharePlay
import XCTest

@MainActor
final class SharePlaySessionTests: XCTestCase {
    private func makePair(hostElection: HostElection = .lowestParticipantID, options: LoopbackHub.Options = LoopbackHub.Options())
        -> (hub: LoopbackHub, a: SharePlaySession, b: SharePlaySession)
    {
        let hub = LoopbackHub(options: options)
        var configuration = SharePlaySession.Configuration()
        configuration.stateRate = 200
        configuration.hostElection = hostElection
        let a = SharePlaySession(transport: hub.makeTransport(id: participantID(1), nearby: true), configuration: configuration)
        let b = SharePlaySession(transport: hub.makeTransport(id: participantID(2)), configuration: configuration)
        return (hub, a, b)
    }

    func testJoinExchangeHostAndLeave() async throws {
        let (_, a, b) = makePair()
        let logA = EventLog(), logB = EventLog()
        logA.attach(to: a)
        logB.attach(to: b)
        let posesA = a.stateChannel(Pose.self)
        let posesB = b.stateChannel(Pose.self)
        let commandsA = a.eventChannel(Command.self)
        let commandsB = b.eventChannel(Command.self)
        a.startObserving()
        b.startObserving()
        XCTAssertEqual(a.state, .idle)

        let startResult = await a.start()
        XCTAssertEqual(startResult, .started)
        try await waitUntil { a.state == .joined && b.state == .joined }
        try await waitUntil { a.others.count == 1 && b.others.count == 1 }
        XCTAssertEqual(a.localParticipantID, participantID(1))
        XCTAssertEqual(a.others.first?.id, participantID(2))
        XCTAssertEqual(b.others.first?.id, participantID(1))
        XCTAssertEqual(b.others.first?.isNearby, true)
        XCTAssertEqual(a.participants.map(\.id), [participantID(1), participantID(2)])
        XCTAssertTrue(a.participants[0].isLocal)
        XCTAssertFalse(a.participants[1].isLocal)
        XCTAssertTrue(a.statusMessage.contains("1 other participant"))

        // Both devices elect the same host: the lowest id.
        XCTAssertEqual(a.hostID, participantID(1))
        XCTAssertEqual(b.hostID, participantID(1))
        XCTAssertTrue(a.isHost)
        XCTAssertFalse(b.isHost)
        XCTAssertTrue(logA.contains(.joined(local: participantID(1))))
        XCTAssertTrue(logA.contains(.participantJoined(participantID(2))))
        XCTAssertTrue(logB.contains(.hostChanged(participantID(1))))

        // State: latest wins, with the plugin's own sequence.
        posesA.publish(Pose(x: 1, y: 2))
        try await waitUntil { posesB.latest(from: participantID(1)) != nil }
        let received = try XCTUnwrap(posesB.latest(from: participantID(1)))
        XCTAssertEqual(received.message, Pose(x: 1, y: 2))
        XCTAssertEqual(received.sequence, 1)
        XCTAssertEqual(received.sender, participantID(1))
        XCTAssertLessThan(received.age, 1)
        XCTAssertNil(posesA.latest(from: participantID(1)), "a sender never receives its own frames")

        // Events: in order, to everyone or to one.
        commandsB.send(.start)
        commandsB.send(.undo(player: 1), to: .only([participantID(1)]))
        commandsB.send(.undo(player: 2), to: .only([participantID(9)]))
        var got: [Command] = []
        try await waitUntil {
            got += commandsA.drain().map(\.message)
            return got.count >= 2
        }
        XCTAssertEqual(got, [.start, .undo(player: 1)])
        XCTAssertTrue(commandsB.drain().isEmpty)

        // A channel registered after the join receives from then on.
        let lateB = b.stateChannel(Pose.self, id: "late")
        a.stateChannel(Pose.self, id: "late").publish(Pose(x: 9, y: 9))
        try await waitUntil { lateB.latest(from: participantID(1))?.message.x == 9 }
        XCTAssertEqual(a.diagnostics.snapshot().channels["late"]?.sentFrames, 1)

        // B leaves: A sees it, keeps the session and the host; B is idle.
        b.leave()
        XCTAssertEqual(b.state, .idle)
        XCTAssertTrue(b.participants.isEmpty)
        XCTAssertNil(b.hostID)
        XCTAssertTrue(logB.contains(.left))
        XCTAssertTrue(logB.contains(.hostChanged(nil)))
        try await waitUntil { a.others.isEmpty }
        XCTAssertEqual(a.state, .joined)
        XCTAssertTrue(logA.contains(.participantLeft(participantID(2))))
        XCTAssertNil(posesA.latest(from: participantID(2)), "what the leaver sent is void")
        XCTAssertEqual(a.hostID, participantID(1))

        a.leave()
        XCTAssertEqual(a.state, .idle)
        XCTAssertNil(a.localParticipantID)
    }

    func testStartWhenNotAvailableStaysIdle() async {
        struct Unavailable: SharePlayTransport {
            func sessions() -> AsyncStream<any SharePlayTransportSession> { AsyncStream { $0.finish() } }
            func start() async -> SharePlayStartResult { .notAvailable }
        }
        let session = SharePlaySession(transport: Unavailable())
        session.startObserving()
        let result = await session.start()
        XCTAssertEqual(result, .notAvailable)
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(session.statusMessage.contains("not available"))
    }

    func testEndInvalidatesTheOthers() async throws {
        let (_, a, b) = makePair()
        let logA = EventLog()
        logA.attach(to: a)
        a.startObserving()
        b.startObserving()
        _ = await a.start()
        try await waitUntil { a.others.count == 1 && b.others.count == 1 }
        b.end()
        try await waitUntil { a.state == .idle }
        XCTAssertTrue(logA.events.contains {
            if case .invalidated = $0 {
                true
            } else {
                false
            }
        })
        XCTAssertTrue(a.statusMessage.hasPrefix("Session ended"))
        XCTAssertTrue(a.participants.isEmpty)
    }

    func testSpatialReportsDriveFlagsAndEvents() async throws {
        let (hub, a, b) = makePair(hostElection: .none)
        let logA = EventLog()
        logA.attach(to: a)
        a.startObserving()
        b.startObserving()
        _ = await a.start()
        try await waitUntil { a.others.count == 1 && b.others.count == 1 }
        XCTAssertNil(a.hostID)
        let sessionA = try XCTUnwrap(hub.session(for: participantID(1)))
        XCTAssertEqual(sessionA.spatialConfiguration?.template, .sideBySide)
        XCTAssertEqual(sessionA.spatialConfiguration?.groupImmersiveSpace, true)

        sessionA.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, remoteIsSpatial: [participantID(2): true], groupImmersion: .requested(.mixed)))
        try await waitUntil { a.isSpatial && a.groupImmersion == .requested(.mixed) }
        XCTAssertEqual(a.others.first?.isSpatial, true)
        XCTAssertEqual(a.participants.first?.isSpatial, true)
        XCTAssertTrue(logA.contains(.spatialChanged(true)))
        XCTAssertTrue(logA.contains(.groupImmersionChanged(.requested(.mixed))))

        sessionA.simulateSpatial(SharePlaySpatialUpdate(localIsSpatial: true, remoteIsSpatial: [participantID(2): true], groupImmersion: .ended))
        try await waitUntil { a.groupImmersion == .ended }
        XCTAssertEqual(logA.events.filter { $0 == .spatialChanged(true) }.count, 1, "unchanged flags do not repeat events")
    }

    func testReorderedStateFramesAreDroppedAsStale() async throws {
        var options = LoopbackHub.Options()
        options.reorderUnreliable = true
        let (_, a, b) = makePair(options: options)
        let posesA = a.stateChannel(Pose.self)
        let posesB = b.stateChannel(Pose.self)
        a.startObserving()
        b.startObserving()
        _ = await a.start()
        try await waitUntil { a.state == .joined && b.state == .joined }

        posesA.publish(Pose(x: 1, y: 0))
        try await waitUntil { a.diagnostics.snapshot().channels["Pose"]?.sentFrames == 1 }
        XCTAssertNil(posesB.latest(from: participantID(1)), "the first frame is held back by the hub")
        posesA.publish(Pose(x: 2, y: 0))
        try await waitUntil { posesB.latest(from: participantID(1)) != nil }
        try await waitUntil { b.diagnostics.snapshot().channels["Pose"]?.droppedStale == 1 }
        XCTAssertEqual(posesB.latest(from: participantID(1))?.message.x, 2)
    }

    func testChannelOfAnotherKindWithTheSameIDIsRefused() {
        let (_, a, _) = makePair()
        _ = a.stateChannel(Pose.self, id: "shared")
        XCTAssertTrue(a.stateChannel(Pose.self, id: "shared") === a.stateChannel(Pose.self, id: "shared"))
    }
}
