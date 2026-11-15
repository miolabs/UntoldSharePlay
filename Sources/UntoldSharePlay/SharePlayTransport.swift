//
//  SharePlayTransport.swift
//  UntoldSharePlay
//
//  The seam between the session and whatever carries it: GroupActivities on
//  the devices, a loopback hub in tests and for two instances of a game on
//  one Mac. Everything the session needs from a transport is here, so nothing
//  else in the package imports GroupActivities.
//

import Foundation

/// How a channel's frames travel.
public enum SharePlayDelivery: Sendable, Hashable, CaseIterable {
    /// In order and retried: events and snapshots.
    case reliable
    /// Fire and forget: state the next frame supersedes.
    case unreliable
}

/// Who receives a frame, by participant id. The sender never receives its own.
public enum SharePlayRecipients: Sendable, Equatable {
    case all
    case only(Set<UUID>)
}

/// What starting an activity reports.
public enum SharePlayStartResult: Sendable, Equatable {
    /// The system accepted the activity; the session arrives through `sessions()`.
    case started
    /// Nothing to share with: no FaceTime call and nobody nearby (visionOS 26).
    case notAvailable
    case cancelled
    case failed(String)
}

public enum SharePlayTransportState: Sendable, Equatable {
    case waiting
    case joined
    case invalidated(String)
}

/// A participant as the transport sees it: the id and, on visionOS 26, whether
/// the person is in the same room as this device.
public struct SharePlayTransportParticipant: Hashable, Sendable {
    public let id: UUID
    public let isNearby: Bool

    public init(id: UUID, isNearby: Bool = false) {
        self.id = id
        self.isNearby = isNearby
    }
}

/// The spatial template the system seats participants with.
public enum SharePlaySpatialTemplate: Sendable, Equatable {
    case none
    case sideBySide
    case conversational
    case surround
    /// A cinema: `seats` in a row `distance` metres in front of the
    /// content at the shared frame's origin, `spacing` metres apart, all
    /// looking at the origin (a darts oche, a screen, a stage). The seats
    /// are at +z, centred on x = 0, on the floor.
    case row(seats: Int, spacing: Double, distance: Double)

    /// The x offsets of a row's seats, centred on zero.
    public static func rowOffsets(seats: Int, spacing: Double) -> [Double] {
        guard seats > 0 else { return [] }
        return (0 ..< seats).map { (Double($0) - Double(seats - 1) / 2) * spacing }
    }
}

/// What the session asks the system coordinator for.
public struct SharePlaySpatialConfiguration: Sendable, Equatable {
    public var groupImmersiveSpace: Bool
    public var template: SharePlaySpatialTemplate

    public init(groupImmersiveSpace: Bool = true, template: SharePlaySpatialTemplate = .sideBySide) {
        self.groupImmersiveSpace = groupImmersiveSpace
        self.template = template
    }
}

public enum SharePlayImmersionStyle: Sendable, Equatable {
    case mixed
    case progressive
    case full
    case other(String)
}

/// The system's opinion on the group immersive space.
public enum SharePlayGroupImmersion: Sendable, Equatable {
    /// No session, or the system has not asked for a space yet.
    case notRequested
    /// Open the immersive space with this style: the group shares it.
    case requested(SharePlayImmersionStyle)
    /// The group left the immersive space: dismiss it.
    case ended
}

/// One update of everything the system coordinator reports.
public struct SharePlaySpatialUpdate: Sendable, Equatable {
    /// Whether this device takes part in the shared spatial arrangement.
    public var localIsSpatial: Bool
    /// The same for the others, where the platform tells (visionOS 26).
    public var remoteIsSpatial: [UUID: Bool]
    public var groupImmersion: SharePlayGroupImmersion
    /// This device's pose in the group's shared frame, when the system gives
    /// one (visionOS 26; at key events such as the sharing start, not per frame).
    public var localPose: SharePlayMatrix?
    /// The others' poses in the shared frame, where the platform tells (visionOS 26).
    public var remotePoses: [UUID: SharePlayMatrix]

    public init(
        localIsSpatial: Bool = false,
        remoteIsSpatial: [UUID: Bool] = [:],
        groupImmersion: SharePlayGroupImmersion = .notRequested,
        localPose: SharePlayMatrix? = nil,
        remotePoses: [UUID: SharePlayMatrix] = [:]
    ) {
        self.localIsSpatial = localIsSpatial
        self.remoteIsSpatial = remoteIsSpatial
        self.groupImmersion = groupImmersion
        self.localPose = localPose
        self.remotePoses = remotePoses
    }
}

/// A frame from another participant.
public struct SharePlayIncoming: Sendable {
    public let data: Data
    public let sender: UUID

    public init(data: Data, sender: UUID) {
        self.data = data
        self.sender = sender
    }
}

/// One delivery mode of one session: a messenger on GroupActivities.
public protocol SharePlayTransportChannel: AnyObject, Sendable {
    func send(_ data: Data, to recipients: SharePlayRecipients) async throws
    /// Frames from the other participants. One consumer.
    var incoming: AsyncStream<SharePlayIncoming> { get }
}

/// One session as the transport sees it. Main actor, like `GroupSession`.
@MainActor
public protocol SharePlayTransportSession: AnyObject, Sendable {
    var localParticipantID: UUID { get }
    /// The session's state, ending with `.invalidated`. One consumer.
    var states: AsyncStream<SharePlayTransportState> { get }
    /// The joined participants, the local one included. One consumer.
    var participants: AsyncStream<Set<SharePlayTransportParticipant>> { get }
    /// The system coordinator's reports; nil where the platform has none.
    /// Available after `configureSpatial`.
    var spatialUpdates: AsyncStream<SharePlaySpatialUpdate>? { get }
    func configureSpatial(_ configuration: SharePlaySpatialConfiguration)
    /// Must be called before `join()`: a channel made later misses early frames.
    func makeChannel(delivery: SharePlayDelivery) -> any SharePlayTransportChannel
    func join()
    func leave()
    func end()
}

public protocol SharePlayTransport: Sendable {
    /// Every session the system hands this app, as they come. One consumer.
    @MainActor func sessions() -> AsyncStream<any SharePlayTransportSession>
    /// Starts the activity: the system's share flow.
    @MainActor func start() async -> SharePlayStartResult
}
