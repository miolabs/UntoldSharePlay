//
//  SharePlaySession.swift
//  UntoldSharePlay
//
//  One object per app: the session's state, its participants and host, the
//  channels, the system's spatial reports, the shared frame and the anchors,
//  and the pump that sends what the channels queued. Main actor and
//  observable, so a window shows it; the channels and the frame it hands out
//  are usable from a render thread.
//

import Foundation
import GroupActivities
import Observation

public enum SharePlayEvent: Sendable, Equatable {
    case joined(local: UUID)
    case participantJoined(UUID)
    case participantLeft(UUID)
    case hostChanged(UUID?)
    case spatialChanged(Bool)
    case groupImmersionChanged(SharePlayGroupImmersion)
    case left
    case invalidated(String)
}

@MainActor
@Observable
public final class SharePlaySession {
    public struct Configuration: Sendable {
        /// Ask the system for a group immersive space (Personas, one shared frame).
        public var groupImmersiveSpace = true
        public var spatialTemplate: SharePlaySpatialTemplate = .sideBySide
        /// Pump rate for the channels, in Hz.
        public var stateRate: Double = 45
        public var hostElection: HostElection = .none

        public init() {}
    }

    public enum State: Sendable, Equatable {
        case idle
        case starting
        case waiting
        case joined
    }

    static let frameChannelID = "untold.shareplay.frame"

    public let configuration: Configuration
    public let diagnostics = SharePlayDiagnostics()
    /// How poses cross the wire; read per frame.
    public let frame = SharedFrame()
    /// Shared world anchors for nearby participants, once a host is attached.
    public let anchors: SharedAnchorTracker
    public private(set) var state: State = .idle
    public private(set) var statusMessage = "Not sharing. Start from a FaceTime call, or share with people nearby."
    public private(set) var localParticipantID: UUID?
    /// Everyone joined, the local participant included, in join order.
    public private(set) var participants: [SharePlayParticipant] = []
    public private(set) var hostID: UUID?
    /// This device takes part in the shared spatial arrangement.
    public private(set) var isSpatial = false
    public private(set) var groupImmersion: SharePlayGroupImmersion = .notRequested

    public var isHost: Bool {
        hostID != nil && hostID == localParticipantID
    }

    /// The participants other than this device, in join order.
    public var others: [SharePlayParticipant] {
        participants.filter { !$0.isLocal }
    }

    @ObservationIgnored private let transport: any SharePlayTransport
    @ObservationIgnored private let router = SharePlayRouter()
    @ObservationIgnored private let frameChannel: SharePlayEventChannel<SharePlayFrameMessage>
    @ObservationIgnored private var transportSession: (any SharePlayTransportSession)?
    @ObservationIgnored private var channelsByDelivery: [SharePlayDelivery: any SharePlayTransportChannel] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observerTask: Task<Void, Never>?
    @ObservationIgnored private var handlers: [UUID: @MainActor (SharePlayEvent) -> Void] = [:]
    @ObservationIgnored private var tickHandlers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var joinedAt: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var remoteSpatial: [UUID: Bool] = [:]

    public init(transport: any SharePlayTransport, configuration: Configuration = Configuration()) {
        self.transport = transport
        self.configuration = configuration
        anchors = SharedAnchorTracker(frame: frame)
        frameChannel = SharePlayEventChannel<SharePlayFrameMessage>(id: Self.frameChannelID, diagnostics: diagnostics)
        router.register(frameChannel)
    }

    /// Over GroupActivities with the game's own activity.
    // swiftformat:disable:next opaqueGenericParameters
    public convenience init<Activity: GroupActivity & Sendable>(
        _ activity: @autoclosure @escaping @Sendable () -> Activity,
        configure: (inout Configuration) -> Void = { _ in }
    ) {
        var configuration = Configuration()
        configure(&configuration)
        self.init(transport: GroupActivitiesTransport(activity()), configuration: configuration)
    }

    // MARK: Lifecycle

    /// Call once at launch: every session the system hands the app is joined.
    public func startObserving() {
        guard observerTask == nil else { return }
        let transport = transport
        observerTask = Task { @MainActor [weak self] in
            for await session in transport.sessions() {
                self?.configure(session)
            }
        }
    }

    /// Starts the activity: the system's share flow (the FaceTime call, or
    /// people nearby on visionOS 26). The session then arrives on its own.
    @discardableResult
    public func start() async -> SharePlayStartResult {
        guard state == .idle else { return .failed("Already in a session") }
        state = .starting
        statusMessage = "Starting SharePlay…"
        let result = await transport.start()
        switch result {
        case .started:
            if state == .starting { statusMessage = "SharePlay started. Waiting for the session…" }
        case .notAvailable:
            statusMessage = "SharePlay is not available: start a FaceTime call, or share with people nearby."
        case .cancelled:
            statusMessage = "SharePlay start cancelled."
        case let .failed(reason):
            statusMessage = "Could not start SharePlay: \(reason)"
        }
        if result != .started, state == .starting { state = .idle }
        SharePlayLog.info("start → \(result)")
        return result
    }

    public func leave() {
        let session = transportSession
        cleanup()
        session?.leave()
        statusMessage = "Left the session."
        SharePlayLog.info("left the session")
        emit(.left)
    }

    /// Ends the session for everyone.
    public func end() {
        let session = transportSession
        cleanup()
        session?.end()
        statusMessage = "Session ended."
        SharePlayLog.info("ended the session")
        emit(.left)
    }

    // MARK: Channels

    /// Unreliable, latest wins. Registered any time; frames for the id flow
    /// as soon as it exists. The id defaults to the message type's name.
    public func stateChannel<Message: Codable & Sendable>(_: Message.Type, id: String? = nil) -> SharePlayStateChannel<Message> {
        let id = id ?? String(describing: Message.self)
        if let existing = router.channel(id: id) {
            guard let typed = existing as? SharePlayStateChannel<Message> else {
                preconditionFailure("SharePlay channel '\(id)' already exists with another kind or message type")
            }
            return typed
        }
        let channel = SharePlayStateChannel<Message>(id: id, diagnostics: diagnostics)
        router.register(channel)
        return channel
    }

    /// Reliable, in order.
    public func eventChannel<Message: Codable & Sendable>(_: Message.Type, id: String? = nil) -> SharePlayEventChannel<Message> {
        let id = id ?? String(describing: Message.self)
        if let existing = router.channel(id: id) {
            guard let typed = existing as? SharePlayEventChannel<Message> else {
                preconditionFailure("SharePlay channel '\(id)' already exists with another kind or message type")
            }
            return typed
        }
        let channel = SharePlayEventChannel<Message>(id: id, diagnostics: diagnostics)
        router.register(channel)
        return channel
    }

    // MARK: Events and ticks

    @discardableResult
    public func addEventHandler(_ handler: @escaping @MainActor (SharePlayEvent) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    public func removeEventHandler(_ id: UUID) {
        handlers[id] = nil
    }

    /// Called once per pump tick while joined, on the main actor, after the
    /// session's own frame messages were handled and before the channels are
    /// flushed.
    @discardableResult
    public func addTickHandler(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        tickHandlers[id] = handler
        return id
    }

    public func removeTickHandler(_ id: UUID) {
        tickHandlers[id] = nil
    }

    /// Opens the coordinator's space when the system asks for the group
    /// immersive space, cycles it on the join (a space opened before the join
    /// stays private), dismisses it when the group leaves its space.
    public func drive(_ coordinator: ImmersiveSpaceCoordinator) {
        addEventHandler { event in
            switch event {
            case .joined:
                coordinator.joinGroup(reason: "session joined")
            case let .groupImmersionChanged(immersion):
                switch immersion {
                case .requested: coordinator.joinGroup(reason: "group immersion requested")
                case .ended: coordinator.dismiss(reason: "group immersion ended")
                case .notRequested: break
                }
            default:
                break
            }
        }
    }

    private func emit(_ event: SharePlayEvent) {
        for handler in handlers.values {
            handler(event)
        }
    }

    // MARK: A session

    private func configure(_ session: any SharePlayTransportSession) {
        if transportSession != nil {
            SharePlayLog.info("a new session replaces the current one")
            cleanup()
        }
        transportSession = session
        localParticipantID = session.localParticipantID
        state = .waiting
        statusMessage = "Session found, joining…"
        SharePlayLog.info("session found, local participant \(session.localParticipantID)")
        router.resetAll()
        diagnostics.reset()
        session.configureSpatial(SharePlaySpatialConfiguration(
            groupImmersiveSpace: configuration.groupImmersiveSpace,
            template: configuration.spatialTemplate
        ))

        // The transport channels and their receive loops exist before the
        // join, so no early frame is lost.
        for delivery in SharePlayDelivery.allCases {
            let channel = session.makeChannel(delivery: delivery)
            channelsByDelivery[delivery] = channel
            let router = router
            let diagnostics = diagnostics
            tasks.append(Task.detached(priority: .userInitiated) {
                for await incoming in channel.incoming {
                    router.route(incoming, diagnostics: diagnostics)
                }
            })
        }
        tasks.append(pumpTask())
        tasks.append(Task { @MainActor [weak self] in
            for await state in session.states {
                self?.apply(transportState: state)
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            for await set in session.participants {
                self?.apply(participants: set)
            }
        })
        if let spatial = session.spatialUpdates {
            tasks.append(Task { @MainActor [weak self] in
                for await update in spatial {
                    self?.apply(spatial: update)
                }
            })
        }
        session.join()
    }

    private func pumpTask() -> Task<Void, Never> {
        let interval = 1.0 / max(configuration.stateRate, 1)
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self, state == .joined {
                    tick()
                    await flush()
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// The session's own traffic: calibrations and anchors in, then out.
    private func tick() {
        for received in frameChannel.drain() {
            switch received.message {
            case let .frameSync(receiverFromSender):
                frame.receiveManual(localFromParticipant: receiverFromSender.matrix, from: received.sender)
                SharePlayLog.info("frame sync received from \(received.sender): \(frame.summary(of: received.sender))")
            case let .sharedAnchor(id):
                anchors.receiveAnnouncement(anchorID: id, from: received.sender)
            case .sharedAnchorRemoved:
                anchors.receiveRemoval(from: received.sender)
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for sync in frame.takeOutgoingSyncs(now: now) {
            frameChannel.send(.frameSync(receiverFromSender: SharePlayMatrix(sync.receiverFromSender)), to: .only([sync.participant]))
            SharePlayLog.info("frame sync sent to \(sync.participant)")
        }
        for announcement in anchors.takeOutgoingAnnouncements() {
            frameChannel.send(announcement.message, to: announcement.recipients)
        }
        for handler in tickHandlers.values {
            handler()
        }
    }

    /// Sends what the channels queued: the state channels' latest, the event
    /// channels' queues in order. Only while joined (frames sent earlier are
    /// dropped by the system).
    private func flush() async {
        for delivery in SharePlayDelivery.allCases {
            guard let channel = channelsByDelivery[delivery] else { continue }
            for frame in router.takeOutgoing(delivery: delivery) {
                do {
                    try await channel.send(frame.data, to: frame.recipients)
                } catch {
                    diagnostics.noteSendFailure()
                    if delivery == .reliable {
                        SharePlayLog.info("a reliable send failed: \(error)")
                    }
                }
            }
        }
    }

    private func apply(transportState: SharePlayTransportState) {
        switch transportState {
        case .waiting:
            if state != .joined { state = .waiting }
        case .joined:
            guard state != .joined else { return }
            state = .joined
            updateJoinedStatus()
            SharePlayLog.info("joined; \(others.count) other participant(s)")
            if let local = localParticipantID {
                emit(.joined(local: local))
            }
            electHost()
            updateFrameParticipants()
        case let .invalidated(reason):
            SharePlayLog.info("session invalidated: \(reason)")
            cleanup()
            statusMessage = "Session ended: \(reason)"
            emit(.invalidated(reason))
        }
    }

    private func apply(participants incoming: Set<SharePlayTransportParticipant>) {
        let now = ProcessInfo.processInfo.systemUptime
        let previousIDs = Set(participants.map(\.id))
        let incomingIDs = Set(incoming.map(\.id))
        var next: [SharePlayParticipant] = []
        for participant in incoming {
            let joined = joinedAt[participant.id] ?? now
            joinedAt[participant.id] = joined
            let isLocal = participant.id == localParticipantID
            let spatial = isLocal ? isSpatial : (remoteSpatial[participant.id] ?? false)
            next.append(SharePlayParticipant(
                id: participant.id, isLocal: isLocal, isNearby: participant.isNearby,
                isSpatial: spatial, joinedAt: joined
            ))
        }
        next.sort { lhs, rhs in
            lhs.joinedAt != rhs.joinedAt ? lhs.joinedAt < rhs.joinedAt : lhs.id.uuidString < rhs.id.uuidString
        }
        participants = next
        for id in previousIDs.subtracting(incomingIDs) where id != localParticipantID {
            joinedAt[id] = nil
            router.forget(participant: id)
            frame.forget(id)
            anchors.forget(id)
            SharePlayLog.info("participant left: \(id)")
            emit(.participantLeft(id))
        }
        for id in incomingIDs.subtracting(previousIDs) where id != localParticipantID {
            let nearby = incoming.first { $0.id == id }?.isNearby ?? false
            SharePlayLog.info("participant joined: \(id), nearby \(nearby)")
            anchors.participantJoined(id)
            emit(.participantJoined(id))
        }
        if state == .joined {
            updateJoinedStatus()
            electHost()
        }
        updateFrameParticipants()
    }

    private func apply(spatial update: SharePlaySpatialUpdate) {
        remoteSpatial = update.remoteIsSpatial
        if isSpatial != update.localIsSpatial {
            isSpatial = update.localIsSpatial
            SharePlayLog.info("spatial: \(isSpatial)")
            emit(.spatialChanged(isSpatial))
        }
        participants = participants.map { participant in
            var updated = participant
            updated.isSpatial = participant.isLocal ? update.localIsSpatial : (update.remoteIsSpatial[participant.id] ?? participant.isSpatial)
            return updated
        }
        if groupImmersion != update.groupImmersion {
            groupImmersion = update.groupImmersion
            SharePlayLog.info("group immersion: \(groupImmersion)")
            emit(.groupImmersionChanged(groupImmersion))
        }
        updateFrameParticipants()
    }

    /// Who shares the system's frame with us, who sits where on the fallback
    /// stage, and whether our shared anchor is wanted.
    private func updateFrameParticipants() {
        let others = others
        for (seat, participant) in others.enumerated() {
            let shares = (isSpatial && participant.isSpatial) || participant.isNearby
            frame.setSharesSystemFrame(shares, for: participant.id)
            frame.setSeat(seat, count: others.count, for: participant.id)
        }
        anchors.update(nearby: Set(others.filter(\.isNearby).map(\.id)), sessionActive: state == .joined)
    }

    private func electHost() {
        let elected = configuration.hostElection.elect(among: Set(participants.map(\.id)))
        guard elected != hostID else { return }
        hostID = elected
        SharePlayLog.info("host: \(elected.map(\.uuidString) ?? "none")\(isHost ? " (this device)" : "")")
        emit(.hostChanged(elected))
    }

    private func updateJoinedStatus() {
        let count = others.count
        statusMessage = count == 0
            ? "Joined. Waiting for others…"
            : "Joined with \(count) other participant\(count == 1 ? "" : "s")."
    }

    private func cleanup() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        channelsByDelivery.removeAll()
        transportSession = nil
        router.resetAll()
        frame.reset()
        anchors.reset()
        participants.removeAll()
        joinedAt.removeAll()
        remoteSpatial.removeAll()
        localParticipantID = nil
        let hadHost = hostID != nil
        hostID = nil
        isSpatial = false
        groupImmersion = .notRequested
        state = .idle
        if hadHost { emit(.hostChanged(nil)) }
    }
}
