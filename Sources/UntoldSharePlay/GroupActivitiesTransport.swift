//
//  GroupActivitiesTransport.swift
//  UntoldSharePlay
//
//  The real transport: GroupActivities. Sessions from `Activity.sessions()`,
//  two messengers per session made before the join, the system coordinator
//  on visionOS (group immersive space, spatial template, who is spatial, the
//  group's immersion style). After Apple's "Implementing SharePlay for
//  immersive spaces in visionOS" and CoolSaber's SaberSessionController.
//

import Combine
import Foundation
import GroupActivities
#if os(visionOS)
    import simd
    import Spatial
    import SwiftUI // the _GroupActivities_SwiftUI overlay: SystemCoordinator.groupImmersionStyle
#endif

#if os(visionOS)
    /// `SharePlaySpatialTemplate.row` as the system's template.
    struct RowTemplate: SpatialTemplate {
        let seats: Int
        let spacing: Double
        let distance: Double

        var elements: [any SpatialTemplateElement] {
            SharePlaySpatialTemplate.rowOffsets(seats: seats, spacing: spacing).map { x in
                SpatialTemplateSeatElement(position: .app.offsetBy(x: x, z: distance), direction: .lookingAt(.app))
            }
        }
    }
#endif

public final class GroupActivitiesTransport<Activity: GroupActivity & Sendable>: SharePlayTransport {
    private let makeActivity: @Sendable () -> Activity
    #if os(visionOS)
        private let customTemplate: (any SpatialTemplate)?
    #endif

    public init(_ activity: @autoclosure @escaping @Sendable () -> Activity) {
        makeActivity = activity
        #if os(visionOS)
            customTemplate = nil
        #endif
    }

    #if os(visionOS)
        /// With a custom spatial template, which wins over the session's
        /// `spatialTemplate` setting.
        public init(_ activity: @autoclosure @escaping @Sendable () -> Activity, spatialTemplate: any SpatialTemplate) {
            makeActivity = activity
            customTemplate = spatialTemplate
        }
    #endif

    @MainActor
    public func sessions() -> AsyncStream<any SharePlayTransportSession> {
        #if os(visionOS)
            let customTemplate = customTemplate
        #endif
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await session in Activity.sessions() {
                    #if os(visionOS)
                        continuation.yield(GroupActivitiesTransportSession(session, customTemplate: customTemplate))
                    #else
                        continuation.yield(GroupActivitiesTransportSession(session))
                    #endif
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    public func start() async -> SharePlayStartResult {
        let activity = makeActivity()
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            do {
                _ = try await activity.activate()
                return .started
            } catch {
                return .failed(error.localizedDescription)
            }
        case .activationDisabled:
            return .notAvailable
        case .cancelled:
            return .cancelled
        @unknown default:
            return .failed("Unknown activation result")
        }
    }
}

/// `GroupSession.systemCoordinator` is an async getter that the compiler will
/// not let a non-Sendable session reach from the main actor; the getter itself
/// is made to be called from anywhere, so this box reads it off the actor.
final class SessionBox<Activity: GroupActivity & Sendable>: @unchecked Sendable {
    private let session: GroupSession<Activity>

    init(_ session: GroupSession<Activity>) {
        self.session = session
    }

    #if os(visionOS)
        func coordinator() async -> SystemCoordinator? {
            await session.systemCoordinator
        }
    #endif
}

/// The joined participants as GroupActivities knows them, for `.only` sends.
final class ParticipantsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var participants: Set<Participant> = []

    var current: Set<Participant> {
        lock.withLock { participants }
    }

    func set(_ participants: Set<Participant>) {
        lock.withLock { self.participants = participants }
    }
}

@MainActor
final class GroupActivitiesTransportSession<Activity: GroupActivity & Sendable>: SharePlayTransportSession {
    let localParticipantID: UUID
    let states: AsyncStream<SharePlayTransportState>
    let participants: AsyncStream<Set<SharePlayTransportParticipant>>
    private(set) var spatialUpdates: AsyncStream<SharePlaySpatialUpdate>?

    private let session: GroupSession<Activity>

    private let sessionBox: SessionBox<Activity>
    private let participantsBox = ParticipantsBox()
    private let stateContinuation: AsyncStream<SharePlayTransportState>.Continuation
    private let participantContinuation: AsyncStream<Set<SharePlayTransportParticipant>>.Continuation
    private var subscriptions: Set<AnyCancellable> = []
    private var tasks: [Task<Void, Never>] = []
    #if os(visionOS)
        private let customTemplate: (any SpatialTemplate)?
        private var coordinator: SystemCoordinator?
        private var spatialState: SpatialState?
    #endif

    #if os(visionOS)
        init(_ session: GroupSession<Activity>, customTemplate: (any SpatialTemplate)?) {
            self.session = session
            sessionBox = SessionBox(session)
            self.customTemplate = customTemplate
            localParticipantID = session.localParticipant.id
            (states, stateContinuation) = AsyncStream.makeStream(of: SharePlayTransportState.self)
            (participants, participantContinuation) = AsyncStream.makeStream(of: Set<SharePlayTransportParticipant>.self)
            observe()
        }
    #else
        init(_ session: GroupSession<Activity>) {
            self.session = session
            sessionBox = SessionBox(session)
            localParticipantID = session.localParticipant.id
            (states, stateContinuation) = AsyncStream.makeStream(of: SharePlayTransportState.self)
            (participants, participantContinuation) = AsyncStream.makeStream(of: Set<SharePlayTransportParticipant>.self)
            observe()
        }
    #endif

    /// `sessions()` emits a session once; its state and participants are
    /// observed per session, on the main queue.
    private func observe() {
        let stateContinuation = stateContinuation
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .waiting:
                    stateContinuation.yield(.waiting)
                case .joined:
                    stateContinuation.yield(.joined)
                case let .invalidated(reason):
                    stateContinuation.yield(.invalidated(reason.localizedDescription))
                    MainActor.assumeIsolated { self?.finish() }
                @unknown default:
                    break
                }
            }
            .store(in: &subscriptions)

        let participantContinuation = participantContinuation
        let box = participantsBox
        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                box.set(active)
                participantContinuation.yield(Set(active.map {
                    SharePlayTransportParticipant(id: $0.id, isNearby: Self.isNearby($0))
                }))
                MainActor.assumeIsolated { self?.refreshRemoteSpatial() }
            }
            .store(in: &subscriptions)
    }

    private static func isNearby(_ participant: Participant) -> Bool {
        #if os(visionOS) || os(iOS)
            if #available(visionOS 26.0, iOS 26.0, *) {
                return participant.isNearbyWithLocalParticipant
            }
        #endif
        return false
    }

    func configureSpatial(_ configuration: SharePlaySpatialConfiguration) {
        #if os(visionOS)
            guard spatialUpdates == nil else { return }
            let (stream, continuation) = AsyncStream.makeStream(of: SharePlaySpatialUpdate.self)
            spatialUpdates = stream
            let state = SpatialState(continuation: continuation)
            spatialState = state
            tasks.append(Task { @MainActor [weak self] in
                guard let self else { return }
                guard let coordinator = await sessionBox.coordinator() else {
                    SharePlayLog.info("no system coordinator for this session: the system gives no shared frame")
                    continuation.finish()
                    return
                }
                var config = SystemCoordinator.Configuration()
                config.supportsGroupImmersiveSpace = configuration.groupImmersiveSpace
                config.spatialTemplatePreference = templatePreference(configuration.template)
                coordinator.configuration = config
                self.coordinator = coordinator
                SharePlayLog.info("system coordinator configured: group immersive space \(configuration.groupImmersiveSpace), template \(configuration.template)")
                tasks.append(Task { @MainActor in
                    for await participantState in coordinator.localParticipantStates {
                        let remote = Self.remoteSpatial(coordinator)
                        let remotePoses = Self.remotePoses(coordinator)
                        let localPose = Self.pose(of: participantState)
                        state.update {
                            $0.localIsSpatial = participantState.isSpatial
                            $0.remoteIsSpatial = remote
                            $0.localPose = localPose
                            $0.remotePoses = remotePoses
                        }
                    }
                })
                tasks.append(Task { @MainActor in
                    for await style in coordinator.groupImmersionStyle {
                        state.update(style: style)
                    }
                })
            })
        #else
            _ = configuration
        #endif
    }

    private func refreshRemoteSpatial() {
        #if os(visionOS)
            guard let coordinator, let spatialState else { return }
            let remote = Self.remoteSpatial(coordinator)
            let remotePoses = Self.remotePoses(coordinator)
            spatialState.update {
                $0.remoteIsSpatial = remote
                $0.remotePoses = remotePoses
            }
        #endif
    }

    #if os(visionOS)
        private static func pose(of state: SystemCoordinator.ParticipantState) -> SharePlayMatrix? {
            if #available(visionOS 26.0, *), let pose = state.pose {
                return SharePlayMatrix(simd_float4x4(pose))
            }
            return nil
        }

        private static func remotePoses(_ coordinator: SystemCoordinator) -> [UUID: SharePlayMatrix] {
            if #available(visionOS 26.0, *) {
                var poses: [UUID: SharePlayMatrix] = [:]
                for (participant, state) in coordinator.remoteParticipantStates {
                    if let pose = state.pose {
                        poses[participant.id] = SharePlayMatrix(simd_float4x4(pose))
                    }
                }
                return poses
            }
            return [:]
        }

        private static func remoteSpatial(_ coordinator: SystemCoordinator) -> [UUID: Bool] {
            if #available(visionOS 26.0, *) {
                return Dictionary(uniqueKeysWithValues: coordinator.remoteParticipantStates.map { ($0.key.id, $0.value.isSpatial) })
            }
            return [:]
        }

        private func templatePreference(_ template: SharePlaySpatialTemplate) -> SpatialTemplatePreference {
            if let customTemplate { return .custom(customTemplate) }
            switch template {
            case .none: return .none
            case .sideBySide: return .sideBySide
            case .conversational: return .conversational
            case .surround: return .surround
            case let .row(seats, spacing, distance): return .custom(RowTemplate(seats: seats, spacing: spacing, distance: distance))
            }
        }
    #endif

    func makeChannel(delivery: SharePlayDelivery) -> any SharePlayTransportChannel {
        let mode: GroupSessionMessenger.DeliveryMode = delivery == .reliable ? .reliable : .unreliable
        let messenger = GroupSessionMessenger(session: session, deliveryMode: mode)
        return GroupActivitiesTransportChannel(messenger: messenger, participants: participantsBox)
    }

    func join() {
        session.join()
    }

    func leave() {
        session.leave()
        finish()
    }

    func end() {
        session.end()
        finish()
    }

    private func finish() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        subscriptions.removeAll()
        stateContinuation.finish()
        participantContinuation.finish()
        #if os(visionOS)
            spatialState?.finish()
            spatialState = nil
            coordinator = nil
        #endif
    }
}

#if os(visionOS)
    /// Accumulates the coordinator's reports into whole updates.
    final class SpatialState: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncStream<SharePlaySpatialUpdate>.Continuation
        private var current = SharePlaySpatialUpdate()
        private var everRequested = false

        init(continuation: AsyncStream<SharePlaySpatialUpdate>.Continuation) {
            self.continuation = continuation
        }

        func update(_ change: (inout SharePlaySpatialUpdate) -> Void) {
            let next: SharePlaySpatialUpdate = lock.withLock {
                change(&current)
                return current
            }
            continuation.yield(next)
        }

        /// nil before any request means none yet; nil after one means the
        /// group left its space.
        func update(style: (any ImmersionStyle)?) {
            update {
                if let style {
                    everRequested = true
                    $0.groupImmersion = .requested(Self.immersionStyle(style))
                } else {
                    $0.groupImmersion = everRequested ? .ended : .notRequested
                }
            }
        }

        func finish() {
            continuation.finish()
        }

        private static func immersionStyle(_ style: any ImmersionStyle) -> SharePlayImmersionStyle {
            let name = String(describing: type(of: style))
            if name.contains("Mixed") { return .mixed }
            if name.contains("Progressive") { return .progressive }
            if name.contains("Full") { return .full }
            return .other(name)
        }
    }
#endif

final class GroupActivitiesTransportChannel: SharePlayTransportChannel, @unchecked Sendable {
    let incoming: AsyncStream<SharePlayIncoming>
    private let messenger: GroupSessionMessenger
    private let participants: ParticipantsBox

    init(messenger: GroupSessionMessenger, participants: ParticipantsBox) {
        self.messenger = messenger
        self.participants = participants
        incoming = AsyncStream { continuation in
            let task = Task {
                for await (data, context) in messenger.messages(of: Data.self) {
                    continuation.yield(SharePlayIncoming(data: data, sender: context.source.id))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func send(_ data: Data, to recipients: SharePlayRecipients) async throws {
        switch recipients {
        case .all:
            try await messenger.send(data, to: .all)
        case let .only(ids):
            let targets = participants.current.filter { ids.contains($0.id) }
            guard !targets.isEmpty else { return }
            try await messenger.send(data, to: .only(targets))
        }
    }
}
