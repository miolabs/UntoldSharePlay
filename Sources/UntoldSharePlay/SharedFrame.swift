//
//  SharedFrame.swift
//  UntoldSharePlay
//
//  How a pose crosses the wire. Two frames: "shared", the group's
//  immersive-space frame, identical on every spatial or nearby device, which
//  is what goes on the wire; and "local", the frame the game simulates in:
//  ARKit's world frame on the engine path (the system never moves it), the
//  scene's frame on a RealityView space (already the shared frame). Per remote
//  participant one mapping is in force, by precedence: the manual calibration
//  the players solved, then the participant's shared world anchor (nearby),
//  then the system's displacement (spatial or nearby, aligned by the system),
//  then a fallback stage pose (remote, not spatial). Lifted from CoolSaber.
//

import Foundation
import simd

/// A rigid transform on the wire, as the four columns of a 4×4 matrix.
public struct SharePlayMatrix: Codable, Hashable, Sendable {
    public var columns: [SIMD4<Float>]

    public init(_ matrix: simd_float4x4) {
        columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
    }

    /// Identity when malformed.
    public var matrix: simd_float4x4 {
        guard columns.count == 4 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (columns[0], columns[1], columns[2], columns[3]))
    }
}

/// Which mapping is in force for a remote participant.
public enum SharePlayAlignment: Sendable, Equatable {
    /// Solved by the players (a shared point and heading); wins over everything.
    case manual
    /// The participant's shared world anchor, placed at their origin (nearby).
    case sharedAnchor
    /// The group immersive space's displacement: the system aligned the spaces.
    case systemDisplacement
    /// A fixed stage pose in front of this device: remote and not spatial.
    case fallbackStage
}

public enum SharePlayCalibrationOutcome: Sendable, Equatable {
    case solved(yawDegrees: Float, offset: SIMD3<Float>)
    case failed(String)
}

public final class SharedFrame: @unchecked Sendable {
    /// Where remote participants without any alignment are placed: a row
    /// `distance` metres ahead, facing this device, `spacing` metres apart.
    public struct FallbackStage: Sendable, Equatable {
        public var distance: Float
        public var spacing: Float

        public init(distance: Float = 2, spacing: Float = 0.8) {
            self.distance = distance
            self.spacing = spacing
        }

        /// local-from-participant for one seat: their origin lands on the row,
        /// their forward points back at us.
        public func pose(seat: Int, count: Int) -> simd_float4x4 {
            let x = (Float(seat) - Float(max(count, 1) - 1) / 2) * spacing
            var matrix = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
            matrix.columns.3 = SIMD4<Float>(x, 0, -distance, 1)
            return matrix
        }
    }

    /// Seconds the nudge sliders must rest before the solution is re-sent.
    public static let nudgeSettleInterval: TimeInterval = 0.3

    private struct Manual {
        var base: simd_float4x4
        var heading: SIMD3<Float>
        var nudge = SIMD2<Float>(0, 0)
        var nudgeDirtyUptime: TimeInterval?
        var summary: String
    }

    private struct Anchor {
        var localFromParticipant: simd_float4x4
        var tracked: Bool
        var summary: String
    }

    private let lock = NSLock()
    private var arkitFromShared = matrix_identity_float4x4
    private var sharedFromARKit = matrix_identity_float4x4
    private var displacementSummaryStorage = "identity"
    private var manual: [UUID: Manual] = [:]
    private var anchors: [UUID: Anchor] = [:]
    private var sharesSystemFrame: Set<UUID> = []
    private var seats: [UUID: (seat: Int, count: Int)] = [:]
    private var pendingSyncs: [(participant: UUID, receiverFromSender: simd_float4x4)] = []
    private var marks: [UUID: simd_float4x4] = [:]
    private var pendingMark: simd_float4x4?
    private var fallbackStageStorage = FallbackStage()

    public init() {}

    // MARK: The system displacement

    /// SwiftUI's `immersiveSpaceDisplacement` as a matrix: a pose in the
    /// group's shared frame times it lands in this device's ARKit frame.
    /// Identity outside a shared session and on a RealityView space.
    public func setSystemDisplacement(_ arkitFromShared: simd_float4x4, summary: String? = nil) {
        lock.withLock {
            self.arkitFromShared = arkitFromShared
            sharedFromARKit = simd_inverse(arkitFromShared)
            displacementSummaryStorage = summary ?? Self.describe(arkitFromShared)
        }
    }

    public var localFromShared: simd_float4x4 {
        lock.withLock { arkitFromShared }
    }

    public var sharedFromLocal: simd_float4x4 {
        lock.withLock { sharedFromARKit }
    }

    public var displacementSummary: String {
        lock.withLock { displacementSummaryStorage }
    }

    public var fallbackStage: FallbackStage {
        get { lock.withLock { fallbackStageStorage } }
        set { lock.withLock { fallbackStageStorage = newValue } }
    }

    // MARK: Per-participant inputs (the session and the anchor tracker)

    /// Spatial with us, or nearby: the system's displacement maps their poses.
    func setSharesSystemFrame(_ shares: Bool, for participant: UUID) {
        lock.withLock {
            if shares {
                sharesSystemFrame.insert(participant)
            } else {
                sharesSystemFrame.remove(participant)
            }
        }
    }

    func setSeat(_ seat: Int, count: Int, for participant: UUID) {
        lock.withLock { seats[participant] = (seat, count) }
    }

    /// The participant's shared anchor in our frame, or nil when removed. A
    /// tracking loss keeps the last pose and says so.
    func setAnchor(localFromParticipant: simd_float4x4?, tracked: Bool, summary: String, for participant: UUID) {
        lock.withLock {
            guard let localFromParticipant else {
                anchors[participant] = nil
                return
            }
            anchors[participant] = Anchor(localFromParticipant: localFromParticipant, tracked: tracked, summary: summary)
        }
    }

    // MARK: Manual calibration

    /// The players touch one physical point and face one way: `localPoint`
    /// and `localHeading` in our local frame, `remotePoint` and
    /// `remoteHeading` as the participant published them (raw). Solves
    /// local-from-participant (a yaw and a translation, both frames being
    /// gravity-aligned), installs it, and queues the inverse for the other
    /// side, so both agree. Nil headings near vertical fail.
    public func calibrate(
        with participant: UUID,
        localPoint: SIMD3<Float>, localHeading: SIMD3<Float>,
        remotePoint: SIMD3<Float>, remoteHeading: SIMD3<Float>
    ) -> SharePlayCalibrationOutcome {
        guard let solved = Self.yawAlignedFrame(
            localPoint: localPoint, localHeading: localHeading,
            remotePoint: remotePoint, remoteHeading: remoteHeading
        ) else {
            return .failed("hold the headings level")
        }
        let offset = SIMD3<Float>(solved.localFromRemote.columns.3.x, solved.localFromRemote.columns.3.y, solved.localFromRemote.columns.3.z)
        let summary = String(format: "manual · yaw %.0f° · offset (%.2f, %.2f, %.2f) m", solved.yawDegrees, offset.x, offset.y, offset.z)
        lock.withLock {
            manual[participant] = Manual(base: solved.localFromRemote, heading: Self.flat(localHeading), summary: summary)
            pendingSyncs.append((participant, simd_inverse(solved.localFromRemote)))
        }
        return .solved(yawDegrees: solved.yawDegrees, offset: offset)
    }

    /// Marks this device's spot for the others: a pose in our local frame (the
    /// head, a controller), sent on the wire as it is. Two people cannot put
    /// their heads in one place at once, so they take turns: one marks and
    /// steps aside, the other stands on the spot, faces the same way and
    /// calibrates to the mark.
    public func publishMark(localPose: simd_float4x4) {
        lock.withLock { pendingMark = sharedFromARKit * localPose }
    }

    /// The participant's last mark, raw (their wire frame), if any.
    public func mark(from participant: UUID) -> simd_float4x4? {
        lock.withLock { marks[participant] }
    }

    /// Calibrates to the participant's mark: `localPoint` and `localHeading`
    /// are ours while standing on the marked spot, facing the marked way.
    public func calibrate(with participant: UUID, localPoint: SIMD3<Float>, localHeading: SIMD3<Float>) -> SharePlayCalibrationOutcome {
        guard let mark = lock.withLock({ marks[participant] }) else {
            return .failed("no mark from the other side yet")
        }
        let remotePoint = SIMD3<Float>(mark.columns.3.x, mark.columns.3.y, mark.columns.3.z)
        let remoteHeading = -SIMD3<Float>(mark.columns.2.x, mark.columns.2.y, mark.columns.2.z)
        return calibrate(
            with: participant,
            localPoint: localPoint, localHeading: localHeading,
            remotePoint: remotePoint, remoteHeading: remoteHeading
        )
    }

    /// An alignment found on this side (a shared anchor) handed to the other:
    /// their local-from-us, so one working direction aligns both.
    func queueSync(for participant: UUID, receiverFromSender: simd_float4x4) {
        lock.withLock { pendingSyncs.append((participant, receiverFromSender)) }
    }

    func takeOutgoingMark() -> simd_float4x4? {
        lock.withLock {
            let mark = pendingMark
            pendingMark = nil
            return mark
        }
    }

    func receiveMark(_ pose: simd_float4x4, from participant: UUID) {
        lock.withLock { marks[participant] = pose }
    }

    /// Fine tune after a calibration: x = side (right +), y = forward, metres,
    /// along the heading captured at calibration. Re-sent once it rests.
    public func setNudge(_ nudge: SIMD2<Float>, for participant: UUID) {
        lock.withLock {
            guard var solution = manual[participant] else { return }
            solution.nudge = nudge
            solution.nudgeDirtyUptime = ProcessInfo.processInfo.systemUptime
            manual[participant] = solution
        }
    }

    public func nudge(for participant: UUID) -> SIMD2<Float> {
        lock.withLock { manual[participant]?.nudge ?? .zero }
    }

    /// The axis the nudges run along follows the player until they nudge.
    public func setNudgeHeading(_ heading: SIMD3<Float>, for participant: UUID) {
        lock.withLock {
            guard var solution = manual[participant], solution.nudge == .zero else { return }
            let flat = SIMD3<Float>(heading.x, 0, heading.z)
            guard simd_length(flat) > 1e-4 else { return }
            solution.heading = simd_normalize(flat)
            manual[participant] = solution
        }
    }

    /// The other side solved it (or settled a nudge): their receiver-from-sender
    /// is our local-from-participant.
    func receiveManual(localFromParticipant: simd_float4x4, from participant: UUID) {
        lock.withLock {
            let heading = manual[participant]?.heading ?? SIMD3<Float>(0, 0, -1)
            let t = localFromParticipant.columns.3
            manual[participant] = Manual(
                base: localFromParticipant, heading: heading,
                summary: String(format: "synced by the other side · offset (%.2f, %.2f, %.2f) m", t.x, t.y, t.z)
            )
        }
    }

    /// What to send: fresh calibrations, and nudges that rested.
    func takeOutgoingSyncs(now: TimeInterval) -> [(participant: UUID, receiverFromSender: simd_float4x4)] {
        lock.withLock {
            var outgoing = pendingSyncs
            pendingSyncs.removeAll()
            for (participant, solution) in manual {
                guard let dirty = solution.nudgeDirtyUptime, now - dirty > Self.nudgeSettleInterval else { continue }
                var settled = solution
                settled.nudgeDirtyUptime = nil
                manual[participant] = settled
                outgoing.append((participant, simd_inverse(Self.composed(settled))))
            }
            return outgoing
        }
    }

    /// A participant left: every mapping for them is void.
    public func forget(_ participant: UUID) {
        lock.withLock {
            manual[participant] = nil
            anchors[participant] = nil
            sharesSystemFrame.remove(participant)
            seats[participant] = nil
            marks[participant] = nil
            pendingSyncs.removeAll { $0.participant == participant }
        }
    }

    /// The session ended.
    public func reset() {
        lock.withLock {
            manual.removeAll()
            anchors.removeAll()
            sharesSystemFrame.removeAll()
            seats.removeAll()
            pendingSyncs.removeAll()
            marks.removeAll()
            pendingMark = nil
            arkitFromShared = matrix_identity_float4x4
            sharedFromARKit = matrix_identity_float4x4
            displacementSummaryStorage = "identity"
        }
    }

    // MARK: Outputs

    public func alignment(of participant: UUID) -> SharePlayAlignment {
        lock.withLock { mappingLocked(for: participant).alignment }
    }

    /// The mapping in force: a pose the participant published, times this,
    /// is in our local frame.
    public func localFromParticipant(_ participant: UUID) -> simd_float4x4 {
        lock.withLock { mappingLocked(for: participant).matrix }
    }

    public func summary(of participant: UUID) -> String {
        lock.withLock {
            switch mappingLocked(for: participant).alignment {
            case .manual: return manual[participant]?.summary ?? "manual"
            case .sharedAnchor: return anchors[participant]?.summary ?? "shared anchor"
            case .systemDisplacement: return "system displacement \(displacementSummaryStorage)"
            case .fallbackStage:
                let seat = seats[participant] ?? (0, 1)
                return "fallback stage, seat \(seat.seat + 1) of \(seat.count)"
            }
        }
    }

    /// Before publishing: our local pose in the shared frame.
    public func toShared(_ local: simd_float4x4) -> simd_float4x4 {
        sharedFromLocal * local
    }

    public func toShared(point: SIMD3<Float>) -> SIMD3<Float> {
        Self.transform(point: point, by: sharedFromLocal)
    }

    public func toShared(direction: SIMD3<Float>) -> SIMD3<Float> {
        Self.transform(direction: direction, by: sharedFromLocal)
    }

    /// After receiving: the participant's wire pose in our local frame.
    public func toLocal(_ wire: simd_float4x4, from participant: UUID) -> simd_float4x4 {
        localFromParticipant(participant) * wire
    }

    public func toLocal(point: SIMD3<Float>, from participant: UUID) -> SIMD3<Float> {
        Self.transform(point: point, by: localFromParticipant(participant))
    }

    public func toLocal(direction: SIMD3<Float>, from participant: UUID) -> SIMD3<Float> {
        Self.transform(direction: direction, by: localFromParticipant(participant))
    }

    // MARK: Math

    /// The rigid transform between two gravity-aligned frames from one shared
    /// physical point and one shared horizontal heading. Both frames have +Y
    /// up (ARKit guarantees it), so only a yaw and a translation are unknown.
    /// Nil when a heading is too close to vertical to define a yaw.
    public static func yawAlignedFrame(
        localPoint: SIMD3<Float>, localHeading: SIMD3<Float>,
        remotePoint: SIMD3<Float>, remoteHeading: SIMD3<Float>
    ) -> (localFromRemote: simd_float4x4, yawDegrees: Float)? {
        let a = SIMD3<Float>(localHeading.x, 0, localHeading.z)
        let b = SIMD3<Float>(remoteHeading.x, 0, remoteHeading.z)
        guard simd_length(a) > 0.2, simd_length(b) > 0.2 else { return nil }
        let an = simd_normalize(a)
        let bn = simd_normalize(b)
        // Rotation about +Y taking the remote heading onto the local one.
        let yaw = atan2(bn.z * an.x - bn.x * an.z, bn.x * an.x + bn.z * an.z)
        let rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let rotated = rotation.act(remotePoint)
        let translation = localPoint - rotated
        var matrix = simd_float4x4(rotation)
        matrix.columns.3 = SIMD4<Float>(translation, 1)
        return (matrix, yaw * 180 / .pi)
    }

    public static func transform(point: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let p = matrix * SIMD4<Float>(point, 1)
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    public static func transform(direction: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let d = matrix * SIMD4<Float>(direction, 0)
        return SIMD3<Float>(d.x, d.y, d.z)
    }

    private static func composed(_ solution: Manual) -> simd_float4x4 {
        guard solution.nudge != .zero else { return solution.base }
        let forward = solution.heading
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let shift = right * solution.nudge.x + forward * solution.nudge.y
        var nudge = matrix_identity_float4x4
        nudge.columns.3 = SIMD4<Float>(shift, 1)
        return nudge * solution.base
    }

    private static func flat(_ heading: SIMD3<Float>) -> SIMD3<Float> {
        let flat = SIMD3<Float>(heading.x, 0, heading.z)
        return simd_length(flat) > 1e-4 ? simd_normalize(flat) : SIMD3<Float>(0, 0, -1)
    }

    private func mappingLocked(for participant: UUID) -> (matrix: simd_float4x4, alignment: SharePlayAlignment) {
        if let solution = manual[participant] {
            return (Self.composed(solution), .manual)
        }
        if let anchor = anchors[participant] {
            return (anchor.localFromParticipant, .sharedAnchor)
        }
        if sharesSystemFrame.contains(participant) {
            return (arkitFromShared, .systemDisplacement)
        }
        let seat = seats[participant] ?? (0, 1)
        return (fallbackStageStorage.pose(seat: seat.seat, count: seat.count), .fallbackStage)
    }

    static func describe(_ matrix: simd_float4x4) -> String {
        guard matrix != matrix_identity_float4x4 else { return "identity" }
        let t = matrix.columns.3
        let yaw = atan2(matrix.columns.0.z, matrix.columns.0.x) * 180 / .pi
        return String(format: "pos (%.2f, %.2f, %.2f) m · yaw %.1f°", t.x, t.y, t.z, -yaw)
    }
}
