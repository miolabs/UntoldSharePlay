//
//  SharePlayParticipants.swift
//  UntoldSharePlay
//

import Foundation

/// A participant of the session, the local one included.
public struct SharePlayParticipant: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var isLocal: Bool
    /// In the same room as this device (visionOS 26 nearby sharing).
    public var isNearby: Bool
    /// Takes part in the shared spatial arrangement (a spatial Persona or a
    /// nearby person); false for a participant in a window.
    public var isSpatial: Bool
    /// This device's uptime when the participant was first seen.
    public let joinedAt: TimeInterval
    /// The participant's pose in the group's shared frame, when the system gave
    /// one (visionOS 26, at key events such as the sharing start).
    public var systemPose: SharePlayMatrix?

    public init(id: UUID, isLocal: Bool, isNearby: Bool = false, isSpatial: Bool = false, joinedAt: TimeInterval) {
        self.id = id
        self.isLocal = isLocal
        self.isNearby = isNearby
        self.isSpatial = isSpatial
        self.joinedAt = joinedAt
    }
}

/// Who is the host, computed the same way on every device from the joined
/// participants. The game decides what the host does (validate, snapshot).
public enum HostElection: Sendable, Equatable {
    /// Symmetric game, no host (CoolSaber).
    case none
    /// The participant with the lowest id string, recomputed on every change
    /// (Oche's rule).
    case lowestParticipantID

    public func elect(among ids: Set<UUID>) -> UUID? {
        switch self {
        case .none:
            nil
        case .lowestParticipantID:
            ids.min { $0.uuidString < $1.uuidString }
        }
    }
}
