import Foundation
@testable import UntoldSharePlay
import XCTest

final class ChannelTests: XCTestCase {
    private let sender = participantID(7)

    func testStateChannelLatestWinsAndSequences() throws {
        let diagnostics = SharePlayDiagnostics()
        let channel = SharePlayStateChannel<Pose>(id: "poses", diagnostics: diagnostics)
        XCTAssertTrue(channel.takeOutgoing().isEmpty)

        channel.publish(Pose(x: 1, y: 0))
        channel.publish(Pose(x: 2, y: 0)) // supersedes the first before the pump ran
        let frames = channel.takeOutgoing()
        XCTAssertEqual(frames.count, 1)
        let frame = try WireFrame.decode(frames[0].data)
        XCTAssertEqual(frame.kind, .state)
        XCTAssertEqual(frame.channelID, "poses")
        XCTAssertEqual(frame.sequence, 1)
        XCTAssertEqual(try JSONDecoder().decode(Pose.self, from: frame.payload), Pose(x: 2, y: 0))
        XCTAssertTrue(channel.takeOutgoing().isEmpty)

        channel.publish(Pose(x: 3, y: 0), to: .only([sender]))
        let second = channel.takeOutgoing()
        XCTAssertEqual(try WireFrame.decode(second[0].data).sequence, 2)
        XCTAssertEqual(second[0].recipients, .only([sender]))
        XCTAssertEqual(diagnostics.snapshot().channels["poses"]?.sentFrames, 2)
    }

    func testStateChannelDropsStaleFramesPerSender() throws {
        let diagnostics = SharePlayDiagnostics()
        let channel = SharePlayStateChannel<Pose>(id: "poses", diagnostics: diagnostics)
        let other = participantID(8)
        func frame(_ sequence: UInt32, x: Float) throws -> WireFrame {
            try WireFrame(kind: .state, channelID: "poses", sequence: sequence, sentUptime: 10, payload: JSONEncoder().encode(Pose(x: x, y: 0)))
        }
        try channel.receive(frame(5, x: 5), from: sender, arrivalUptime: 100)
        try channel.receive(frame(4, x: 4), from: sender, arrivalUptime: 101) // out of order: dropped
        try channel.receive(frame(5, x: 55), from: sender, arrivalUptime: 102) // duplicate: dropped
        try channel.receive(frame(6, x: 6), from: sender, arrivalUptime: 103)
        try channel.receive(frame(1, x: 1), from: other, arrivalUptime: 104) // another sender's own sequence

        XCTAssertEqual(channel.latest(from: sender)?.message, Pose(x: 6, y: 0))
        XCTAssertEqual(channel.latest(from: sender)?.sequence, 6)
        XCTAssertEqual(channel.latest(from: sender)?.arrivalUptime, 103)
        XCTAssertEqual(channel.latest(from: other)?.message, Pose(x: 1, y: 0))
        XCTAssertEqual(channel.latestAll().count, 2)
        XCTAssertEqual(diagnostics.snapshot().channels["poses"]?.droppedStale, 2)
        XCTAssertEqual(diagnostics.snapshot().channels["poses"]?.receivedFrames, 3)

        channel.forget(sender)
        XCTAssertNil(channel.latest(from: sender))
        // A sender that restarts after being forgotten is accepted again.
        try channel.receive(frame(1, x: 9), from: sender, arrivalUptime: 105)
        XCTAssertEqual(channel.latest(from: sender)?.message.x, 9)
    }

    func testStateChannelWrapAround() throws {
        let channel = SharePlayStateChannel<Pose>(id: "poses", diagnostics: SharePlayDiagnostics())
        let payload = try JSONEncoder().encode(Pose(x: 0, y: 0))
        channel.receive(WireFrame(kind: .state, channelID: "poses", sequence: UInt32.max, sentUptime: 0, payload: payload), from: sender, arrivalUptime: 1)
        channel.receive(WireFrame(kind: .state, channelID: "poses", sequence: 0, sentUptime: 0, payload: payload), from: sender, arrivalUptime: 2)
        XCTAssertEqual(channel.latest(from: sender)?.sequence, 0)
    }

    func testStateChannelReportsUndecodablePayloadOnce() {
        let diagnostics = SharePlayDiagnostics()
        let channel = SharePlayStateChannel<Pose>(id: "poses", diagnostics: diagnostics)
        channel.receive(WireFrame(kind: .state, channelID: "poses", sequence: 1, sentUptime: 0, payload: Data("nope".utf8)), from: sender, arrivalUptime: 1)
        channel.receive(WireFrame(kind: .state, channelID: "poses", sequence: 2, sentUptime: 0, payload: Data("nope".utf8)), from: sender, arrivalUptime: 2)
        XCTAssertNil(channel.latest(from: sender))
        XCTAssertEqual(diagnostics.snapshot().channels["poses"]?.decodeFailures, 2)
    }

    func testEventChannelKeepsOrder() throws {
        let diagnostics = SharePlayDiagnostics()
        let channel = SharePlayEventChannel<Command>(id: "commands", diagnostics: diagnostics)
        channel.send(.start)
        channel.send(.undo(player: 2), to: .only([sender]))
        channel.send(.undo(player: 3))
        XCTAssertEqual(channel.pendingCount, 3)
        let frames = channel.takeOutgoing()
        XCTAssertEqual(channel.pendingCount, 0)
        XCTAssertEqual(frames.count, 3)
        let decoded = try frames.map { try WireFrame.decode($0.data) }
        XCTAssertEqual(decoded.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(decoded.map(\.kind), [.event, .event, .event])
        XCTAssertEqual(frames[1].recipients, .only([sender]))
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: decoded[1].payload), .undo(player: 2))

        for frame in decoded {
            channel.receive(frame, from: sender, arrivalUptime: 50)
        }
        let received = channel.drain()
        XCTAssertEqual(received.map(\.message), [.start, .undo(player: 2), .undo(player: 3)])
        XCTAssertEqual(received.map(\.sender), [sender, sender, sender])
        XCTAssertTrue(channel.drain().isEmpty)
    }

    func testResetClearsQueuesAndState() throws {
        let state = SharePlayStateChannel<Pose>(id: "poses", diagnostics: SharePlayDiagnostics())
        state.publish(Pose(x: 1, y: 1))
        try state.receive(WireFrame(kind: .state, channelID: "poses", sequence: 1, sentUptime: 0, payload: JSONEncoder().encode(Pose(x: 2, y: 2))), from: sender, arrivalUptime: 1)
        state.reset()
        XCTAssertTrue(state.takeOutgoing().isEmpty)
        XCTAssertTrue(state.latestAll().isEmpty)

        let events = SharePlayEventChannel<Command>(id: "commands", diagnostics: SharePlayDiagnostics())
        events.send(.start)
        events.reset()
        XCTAssertEqual(events.pendingCount, 0)
    }

    func testRouterDispatchesByChannelID() throws {
        let diagnostics = SharePlayDiagnostics()
        let router = SharePlayRouter()
        let poses = SharePlayStateChannel<Pose>(id: "poses", diagnostics: diagnostics)
        let commands = SharePlayEventChannel<Command>(id: "commands", diagnostics: diagnostics)
        router.register(poses)
        router.register(commands)

        let poseFrame = try WireFrame(kind: .state, channelID: "poses", sequence: 1, sentUptime: 0, payload: JSONEncoder().encode(Pose(x: 4, y: 4)))
        let commandFrame = try WireFrame(kind: .event, channelID: "commands", sequence: 1, sentUptime: 0, payload: JSONEncoder().encode(Command.start))
        let strayFrame = WireFrame(kind: .event, channelID: "elsewhere", sequence: 1, sentUptime: 0, payload: Data())
        router.route(SharePlayIncoming(data: poseFrame.encoded(), sender: sender), diagnostics: diagnostics)
        router.route(SharePlayIncoming(data: commandFrame.encoded(), sender: sender), diagnostics: diagnostics)
        router.route(SharePlayIncoming(data: strayFrame.encoded(), sender: sender), diagnostics: diagnostics)
        router.route(SharePlayIncoming(data: Data([0, 1]), sender: sender), diagnostics: diagnostics)

        XCTAssertEqual(poses.latest(from: sender)?.message, Pose(x: 4, y: 4))
        XCTAssertEqual(commands.drain().map(\.message), [.start])
        XCTAssertEqual(diagnostics.snapshot().unroutedFrames, 1)
        XCTAssertEqual(diagnostics.snapshot().undecodableFrames, 1)

        poses.publish(Pose(x: 1, y: 1))
        commands.send(.start)
        XCTAssertEqual(router.takeOutgoing(delivery: .unreliable).count, 1)
        XCTAssertEqual(router.takeOutgoing(delivery: .reliable).count, 1)
        XCTAssertTrue(router.takeOutgoing(delivery: .reliable).isEmpty)
        XCTAssertTrue(diagnostics.summary().contains("poses"))
    }
}
