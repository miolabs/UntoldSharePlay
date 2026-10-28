//
//  SharedAnchorTracker.swift
//  UntoldSharePlay
//
//  Shared world anchors (visionOS 26): the system's way of giving two
//  headsets in one room a common reference. Each device places one anchor at
//  its own ARKit origin, shared with nearby participants; on the other device
//  that anchor's pose is local-from-the-participant. ARKit does not say who
//  placed a shared anchor, so each device announces its anchor's id on the
//  session's frame channel; until the announcement arrives, an unknown shared
//  anchor with exactly one nearby participant is taken to be theirs
//  (CoolSaber's two-player rule). The host of the anchors is the engine's XR
//  runtime behind `SharePlayWorldAnchorHost`; a fake stands in for the tests.
//

import Foundation
import simd

/// One change to a world anchor, as the host reports it.
public struct SharePlayAnchorUpdate: Sendable, Equatable {
    public enum Event: Sendable {
        case added
        case updated
        case removed
    }

    /// The anchor's id: a shared anchor keeps it on every device.
    public let id: UUID
    /// The anchor's pose in this device's local (ARKit) frame.
    public let localFromAnchor: simd_float4x4
    public let isTracked: Bool
    /// Shared with nearby participants: ours as well as theirs.
    public let isShared: Bool
    /// Requested by this device.
    public let isOwn: Bool
    public let event: Event

    public init(id: UUID, localFromAnchor: simd_float4x4, isTracked: Bool, isShared: Bool, isOwn: Bool, event: Event) {
        self.id = id
        self.localFromAnchor = localFromAnchor
        self.isTracked = isTracked
        self.isShared = isShared
        self.isOwn = isOwn
        self.event = event
    }
}

/// What the tracker needs from a world-tracking runtime: the engine's
/// `UntoldEngineXR` once its world-anchor API ships, a fake in the tests.
public protocol SharePlayWorldAnchorHost: AnyObject, Sendable {
    /// Requests an anchor at `localFromAnchor`, shared with nearby participants,
    /// kept across provider restarts. Returns a handle, or nil without ARKit.
    func addSharedWorldAnchor(localFromAnchor: simd_float4x4) -> UUID?
    func removeWorldAnchor(_ handle: UUID)
    /// Every anchor update the runtime reports, on an arbitrary thread.
    func addWorldAnchorObserver(_ handler: @escaping @Sendable (SharePlayAnchorUpdate) -> Void) -> UUID
    func removeWorldAnchorObserver(_ id: UUID)
}

public final class SharedAnchorTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let frame: SharedFrame
    private var host: (any SharePlayWorldAnchorHost)?
    private var observerID: UUID?
    private var ownHandle: UUID?
    private var ownAnchorIDStorage: UUID?
    private var ownTracked = false
    private var nearby: Set<UUID> = []
    private var sessionActive = false
    private var owners: [UUID: UUID] = [:] // anchor id → participant
    private var unattributed: [UUID: SharePlayAnchorUpdate] = [:]
    private var outgoing: [(message: SharePlayFrameMessage, recipients: SharePlayRecipients)] = []

    init(frame: SharedFrame) {
        self.frame = frame
    }

    /// The id of this device's shared anchor once ARKit reported it.
    public var ownAnchorID: UUID? {
        lock.withLock { ownAnchorIDStorage }
    }

    public var isAttached: Bool {
        lock.withLock { host != nil }
    }

    /// Our anchor is placed as soon as the session is joined and someone is nearby.
    public var wantsOwnAnchor: Bool {
        lock.withLock { sessionActive && !nearby.isEmpty }
    }

    public var summary: String {
        lock.withLock {
            guard host != nil else { return "no anchor host" }
            guard sessionActive, !nearby.isEmpty else { return "no nearby participant" }
            guard let id = ownAnchorIDStorage else { return ownHandle == nil ? "own anchor not requested" : "own anchor pending" }
            return "own anchor \(id.uuidString.prefix(8)) \(ownTracked ? "tracked" : "NOT tracked")"
        }
    }

    // MARK: The host

    public func attach(_ host: any SharePlayWorldAnchorHost) {
        detach()
        lock.withLock { self.host = host }
        let id = host.addWorldAnchorObserver { [weak self] update in
            self?.handle(update)
        }
        lock.withLock { observerID = id }
        reconcile()
    }

    public func detach() {
        let (host, observer, handle): ((any SharePlayWorldAnchorHost)?, UUID?, UUID?) = lock.withLock {
            let values = (self.host, observerID, ownHandle)
            self.host = nil
            observerID = nil
            ownHandle = nil
            ownAnchorIDStorage = nil
            ownTracked = false
            return values
        }
        if let observer { host?.removeWorldAnchorObserver(observer) }
        if let handle { host?.removeWorldAnchor(handle) }
    }

    // MARK: The session

    func update(nearby: Set<UUID>, sessionActive: Bool) {
        lock.withLock {
            self.nearby = nearby
            self.sessionActive = sessionActive
        }
        reconcile()
    }

    func participantJoined(_ participant: UUID) {
        lock.withLock {
            if let id = ownAnchorIDStorage {
                outgoing.append((.sharedAnchor(id: id), .only([participant])))
            }
        }
    }

    func forget(_ participant: UUID) {
        lock.withLock {
            for (anchor, owner) in owners where owner == participant {
                owners[anchor] = nil
            }
        }
        frame.setAnchor(localFromParticipant: nil, tracked: false, summary: "", for: participant)
    }

    func reset() {
        lock.withLock {
            nearby.removeAll()
            sessionActive = false
            owners.removeAll()
            unattributed.removeAll()
            outgoing.removeAll()
        }
        reconcile()
    }

    func receiveAnnouncement(anchorID: UUID, from participant: UUID) {
        let pending: SharePlayAnchorUpdate? = lock.withLock {
            owners[anchorID] = participant
            return unattributed.removeValue(forKey: anchorID)
        }
        if let pending { apply(pending, to: participant) }
    }

    func receiveRemoval(from participant: UUID) {
        forget(participant)
    }

    func takeOutgoingAnnouncements() -> [(message: SharePlayFrameMessage, recipients: SharePlayRecipients)] {
        lock.withLock {
            let messages = outgoing
            outgoing.removeAll()
            return messages
        }
    }

    // MARK: Anchors

    /// Places or removes our anchor to match `wantsOwnAnchor`.
    private func reconcile() {
        let action: (host: any SharePlayWorldAnchorHost, place: Bool, handle: UUID?)? = lock.withLock {
            guard let host else { return nil }
            let wanted = sessionActive && !nearby.isEmpty
            if wanted, ownHandle == nil { return (host, true, nil) }
            if !wanted, let handle = ownHandle { return (host, false, handle) }
            return nil
        }
        guard let action else { return }
        if action.place {
            let handle = action.host.addSharedWorldAnchor(localFromAnchor: matrix_identity_float4x4)
            lock.withLock { ownHandle = handle }
            SharePlayLog.info("anchor: placing our shared anchor at the origin (handle \(handle.map(\.uuidString) ?? "none"))")
        } else if let handle = action.handle {
            action.host.removeWorldAnchor(handle)
            let hadID: Bool = lock.withLock {
                ownHandle = nil
                let had = ownAnchorIDStorage != nil
                ownAnchorIDStorage = nil
                ownTracked = false
                if had { outgoing.append((.sharedAnchorRemoved, .all)) }
                return had
            }
            SharePlayLog.info("anchor: removed our shared anchor\(hadID ? ", told the others" : "")")
        }
    }

    private func handle(_ update: SharePlayAnchorUpdate) {
        if update.isOwn {
            guard update.isShared else { return }
            let announce: Bool = lock.withLock {
                switch update.event {
                case .removed:
                    ownAnchorIDStorage = nil
                    ownTracked = false
                    return false
                case .added, .updated:
                    ownTracked = update.isTracked
                    guard ownAnchorIDStorage != update.id else { return false }
                    ownAnchorIDStorage = update.id
                    outgoing.append((.sharedAnchor(id: update.id), .all))
                    return true
                }
            }
            if announce { SharePlayLog.info("anchor: our shared anchor is \(update.id), telling the others") }
            return
        }
        guard update.isShared else { return }
        let owner: UUID? = lock.withLock {
            if let owner = owners[update.id] { return owner }
            if nearby.count == 1, let only = nearby.first {
                owners[update.id] = only
                return only
            }
            if update.event == .removed {
                unattributed[update.id] = nil
            } else {
                unattributed[update.id] = update
            }
            return nil
        }
        guard let owner else { return }
        apply(update, to: owner)
    }

    private func apply(_ update: SharePlayAnchorUpdate, to participant: UUID) {
        switch update.event {
        case .removed:
            frame.setAnchor(localFromParticipant: nil, tracked: false, summary: "", for: participant)
            SharePlayLog.info("anchor: \(participant)'s shared anchor removed")
        case .added, .updated:
            let t = update.localFromAnchor.columns.3
            let yaw = atan2(update.localFromAnchor.columns.0.z, update.localFromAnchor.columns.0.x) * 180 / .pi
            let summary = String(
                format: "shared anchor %@ · yaw %.0f° · offset (%.2f, %.2f, %.2f) m",
                update.isTracked ? "tracked" : "NOT tracked", -yaw, t.x, t.y, t.z
            )
            frame.setAnchor(localFromParticipant: update.localFromAnchor, tracked: update.isTracked, summary: summary, for: participant)
            if update.event == .added { SharePlayLog.info("anchor: \(participant)'s shared anchor \(update.id) — \(summary)") }
        }
    }
}

/// The session's own messages on its frame channel.
enum SharePlayFrameMessage: Codable, Sendable, Equatable {
    /// The sender solved the alignment: `receiverFromSender` maps the sender's
    /// wire frame into the receiver's.
    case frameSync(receiverFromSender: SharePlayMatrix)
    /// The sender's shared world anchor has this id.
    case sharedAnchor(id: UUID)
    case sharedAnchorRemoved
    /// The sender marked a spot: a pose in the sender's wire frame for the
    /// others to stand on and calibrate to.
    case mark(pose: SharePlayMatrix)
}
