//
//  LoopbackTransport.swift
//  UntoldSharePlay
//
//  An in-process transport: every transport made by one hub is one
//  participant. The first `start()` opens a session for all of them; each
//  joins on its own, as devices do. Frames go to the other joined
//  participants' channels of the same delivery, with optional loss,
//  reordering and delay on the unreliable path. For the tests, and for two
//  instances of a game on one Mac.
//

import Foundation

public final class LoopbackHub: @unchecked Sendable {
    public struct Options: Sendable {
        /// Probability, 0...1, that an unreliable frame is lost.
        public var unreliableLoss: Double = 0
        /// Holds every other unreliable frame back so pairs arrive swapped.
        public var reorderUnreliable = false
        /// Added to every unreliable frame.
        public var delay: TimeInterval = 0
        public var seed: UInt64 = 1

        public init() {}
    }

    private let lock = NSLock()
    private let options: Options
    private var random: SplitMix64
    private var members: [UUID: LoopbackTransport] = [:]
    private var memberOrder: [UUID] = []
    private var nearbyMembers: Set<UUID> = []
    private var sessionActive = false
    private var joined: Set<UUID> = []
    private var stateContinuations: [UUID: AsyncStream<SharePlayTransportState>.Continuation] = [:]
    private var participantContinuations: [UUID: AsyncStream<Set<SharePlayTransportParticipant>>.Continuation] = [:]
    private var channels: [UUID: [SharePlayDelivery: LoopbackChannel]] = [:]
    private var heldBack: [ObjectIdentifier: SharePlayIncoming] = [:]
    private var sessions: [UUID: LoopbackSession] = [:]

    public init(options: Options = Options()) {
        self.options = options
        random = SplitMix64(state: options.seed)
    }

    /// One participant. `nearby` flags it as being in the room with everyone.
    @MainActor
    public func makeTransport(id: UUID = UUID(), nearby: Bool = false) -> LoopbackTransport {
        let transport = LoopbackTransport(id: id, hub: self)
        lock.withLock {
            members[id] = transport
            memberOrder.append(id)
            if nearby { nearbyMembers.insert(id) }
        }
        return transport
    }

    /// The active session of a participant, for simulating the system's reports.
    @MainActor
    public func session(for participant: UUID) -> LoopbackSession? {
        lock.withLock { sessions[participant] }
    }

    public var isSessionActive: Bool {
        lock.withLock { sessionActive }
    }

    // MARK: Session lifecycle (main actor: it creates sessions)

    @MainActor
    func startSession() -> SharePlayStartResult {
        let (alreadyActive, transports): (Bool, [LoopbackTransport]) = lock.withLock {
            if sessionActive { return (true, []) }
            sessionActive = true
            joined.removeAll()
            return (false, memberOrder.compactMap { members[$0] })
        }
        guard !alreadyActive else { return .started }
        for transport in transports {
            let session = LoopbackSession(participantID: transport.id, hub: self)
            lock.withLock {
                sessions[transport.id] = session
                stateContinuations[transport.id] = session.stateContinuation
                participantContinuations[transport.id] = session.participantContinuation
            }
            transport.deliver(session)
        }
        return .started
    }

    func join(_ id: UUID) {
        let (state, broadcast): (AsyncStream<SharePlayTransportState>.Continuation?, [Broadcast]) = lock.withLock {
            guard sessionActive else { return (nil, []) }
            joined.insert(id)
            return (stateContinuations[id], participantsBroadcastLocked())
        }
        state?.yield(.joined)
        deliver(broadcast)
    }

    func leave(_ id: UUID) {
        let (state, broadcast, ended): (AsyncStream<SharePlayTransportState>.Continuation?, [Broadcast], [AsyncStream<SharePlayTransportState>.Continuation]) = lock.withLock {
            guard sessionActive else { return (nil, [], []) }
            joined.remove(id)
            // Taken out before `finishLocked`, so the "left" state is yielded
            // before the stream is finished.
            let state = stateContinuations.removeValue(forKey: id)
            finishLocked(id)
            if joined.isEmpty {
                return (state, [], endLocked())
            }
            return (state, participantsBroadcastLocked(), [])
        }
        state?.yield(.invalidated("left"))
        state?.finish()
        deliver(broadcast)
        for continuation in ended {
            continuation.yield(.invalidated("everyone left"))
            continuation.finish()
        }
    }

    func end() {
        let ended = lock.withLock { endLocked() }
        for continuation in ended {
            continuation.yield(.invalidated("ended"))
            continuation.finish()
        }
    }

    func register(_ channel: LoopbackChannel, for id: UUID, delivery: SharePlayDelivery) {
        lock.withLock { channels[id, default: [:]][delivery] = channel }
    }

    func route(_ data: Data, from sender: UUID, delivery: SharePlayDelivery, to recipients: SharePlayRecipients) {
        let targets: [LoopbackChannel] = lock.withLock {
            guard sessionActive, joined.contains(sender) else { return [] }
            return joined.subtracting([sender]).filter { id in
                switch recipients {
                case .all: true
                case let .only(ids): ids.contains(id)
                }
            }.compactMap { channels[$0]?[delivery] }
        }
        for target in targets {
            let incoming = SharePlayIncoming(data: data, sender: sender)
            switch delivery {
            case .reliable:
                target.deliver(incoming)
            case .unreliable:
                deliverUnreliable(incoming, to: target)
            }
        }
    }

    private func deliverUnreliable(_ incoming: SharePlayIncoming, to target: LoopbackChannel) {
        let plan: (drop: Bool, frames: [SharePlayIncoming]) = lock.withLock {
            if options.unreliableLoss > 0, Double.random(in: 0 ..< 1, using: &random) < options.unreliableLoss {
                return (true, [])
            }
            guard options.reorderUnreliable else { return (false, [incoming]) }
            let key = ObjectIdentifier(target)
            if let held = heldBack.removeValue(forKey: key) {
                return (false, [incoming, held])
            }
            heldBack[key] = incoming
            return (false, [])
        }
        guard !plan.drop else { return }
        for frame in plan.frames {
            if options.delay > 0 {
                let delay = options.delay
                Task.detached {
                    try? await Task.sleep(for: .seconds(delay))
                    target.deliver(frame)
                }
            } else {
                target.deliver(frame)
            }
        }
    }

    // MARK: Locked helpers (yields happen outside the lock)

    private struct Broadcast {
        let continuation: AsyncStream<Set<SharePlayTransportParticipant>>.Continuation
        let participants: Set<SharePlayTransportParticipant>
    }

    private func participantsBroadcastLocked() -> [Broadcast] {
        let set = Set(joined.map { SharePlayTransportParticipant(id: $0, isNearby: nearbyMembers.contains($0)) })
        return joined.compactMap { id in
            participantContinuations[id].map { Broadcast(continuation: $0, participants: set) }
        }
    }

    private func deliver(_ broadcast: [Broadcast]) {
        for item in broadcast {
            item.continuation.yield(item.participants)
        }
    }

    /// Ends the session for everyone still in it; returns the state
    /// continuations of the joined participants, to invalidate outside the lock.
    private func endLocked() -> [AsyncStream<SharePlayTransportState>.Continuation] {
        let joinedContinuations = joined.compactMap { stateContinuations[$0] }
        for id in Array(stateContinuations.keys) where !joined.contains(id) {
            finishLocked(id)
        }
        for id in joined {
            participantContinuations.removeValue(forKey: id)?.finish()
            stateContinuations[id] = nil
            channels[id]?.values.forEach { $0.finish() }
            channels[id] = nil
            sessions[id] = nil
        }
        joined.removeAll()
        sessionActive = false
        heldBack.removeAll()
        return joinedContinuations
    }

    private func finishLocked(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)?.finish()
        participantContinuations.removeValue(forKey: id)?.finish()
        channels[id]?.values.forEach { $0.finish() }
        channels[id] = nil
        sessions[id] = nil
    }
}

public final class LoopbackTransport: SharePlayTransport, @unchecked Sendable {
    public let id: UUID
    private let hub: LoopbackHub
    private let lock = NSLock()
    private var continuation: AsyncStream<any SharePlayTransportSession>.Continuation?
    private var pending: [LoopbackSession] = []

    init(id: UUID, hub: LoopbackHub) {
        self.id = id
        self.hub = hub
    }

    @MainActor
    public func sessions() -> AsyncStream<any SharePlayTransportSession> {
        let (stream, continuation) = AsyncStream.makeStream(of: (any SharePlayTransportSession).self)
        let queued: [LoopbackSession] = lock.withLock {
            self.continuation = continuation
            let queued = pending
            pending.removeAll()
            return queued
        }
        for session in queued {
            continuation.yield(session)
        }
        return stream
    }

    @MainActor
    public func start() async -> SharePlayStartResult {
        hub.startSession()
    }

    /// Hands the session to `sessions()`, or holds it until that is called.
    /// Written without a `withLock` closure on purpose: on Swift 6.3.3 (Xcode
    /// 26.6) the compiler's closure-lifetime pass never finishes on the
    /// closure this used to be (capturing `session`, returning the optional
    /// continuation), and `swift build` hung for hours.
    func deliver(_ session: LoopbackSession) {
        lock.lock()
        let continuation = continuation
        if continuation == nil { pending.append(session) }
        lock.unlock()
        continuation?.yield(session)
    }
}

@MainActor
public final class LoopbackSession: SharePlayTransportSession {
    public let localParticipantID: UUID
    public let states: AsyncStream<SharePlayTransportState>
    public let participants: AsyncStream<Set<SharePlayTransportParticipant>>
    public private(set) var spatialUpdates: AsyncStream<SharePlaySpatialUpdate>?
    public private(set) var spatialConfiguration: SharePlaySpatialConfiguration?

    let stateContinuation: AsyncStream<SharePlayTransportState>.Continuation
    let participantContinuation: AsyncStream<Set<SharePlayTransportParticipant>>.Continuation
    private var spatialContinuation: AsyncStream<SharePlaySpatialUpdate>.Continuation?
    private let hub: LoopbackHub

    init(participantID: UUID, hub: LoopbackHub) {
        localParticipantID = participantID
        self.hub = hub
        (states, stateContinuation) = AsyncStream.makeStream(of: SharePlayTransportState.self)
        (participants, participantContinuation) = AsyncStream.makeStream(of: Set<SharePlayTransportParticipant>.self)
        stateContinuation.yield(.waiting)
    }

    public func configureSpatial(_ configuration: SharePlaySpatialConfiguration) {
        spatialConfiguration = configuration
        let (stream, continuation) = AsyncStream.makeStream(of: SharePlaySpatialUpdate.self)
        spatialUpdates = stream
        spatialContinuation = continuation
    }

    /// What the system coordinator would report: for the tests.
    public func simulateSpatial(_ update: SharePlaySpatialUpdate) {
        spatialContinuation?.yield(update)
    }

    public func makeChannel(delivery: SharePlayDelivery) -> any SharePlayTransportChannel {
        let channel = LoopbackChannel(owner: localParticipantID, delivery: delivery, hub: hub)
        hub.register(channel, for: localParticipantID, delivery: delivery)
        return channel
    }

    public func join() {
        hub.join(localParticipantID)
    }

    public func leave() {
        hub.leave(localParticipantID)
    }

    public func end() {
        hub.end()
    }
}

final class LoopbackChannel: SharePlayTransportChannel, @unchecked Sendable {
    let incoming: AsyncStream<SharePlayIncoming>
    private let continuation: AsyncStream<SharePlayIncoming>.Continuation
    private let owner: UUID
    private let delivery: SharePlayDelivery
    private let hub: LoopbackHub

    init(owner: UUID, delivery: SharePlayDelivery, hub: LoopbackHub) {
        self.owner = owner
        self.delivery = delivery
        self.hub = hub
        (incoming, continuation) = AsyncStream.makeStream(of: SharePlayIncoming.self)
    }

    func send(_ data: Data, to recipients: SharePlayRecipients) async throws {
        hub.route(data, from: owner, delivery: delivery, to: recipients)
    }

    func deliver(_ frame: SharePlayIncoming) {
        continuation.yield(frame)
    }

    func finish() {
        continuation.finish()
    }
}

/// A small seeded generator so loss and reordering replay the same way.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
