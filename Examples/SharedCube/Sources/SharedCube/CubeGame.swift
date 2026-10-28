//
//  CubeGame.swift
//  SharedCube
//
//  Per frame, on the render thread: publish our head pose in the shared
//  frame; put a cube at every other participant's head, mapped into our
//  frame by the session's shared frame (manual calibration, shared anchor,
//  the system's displacement, or the fallback stage); honour the window's
//  calibration request.
//

import Foundation
import simd
import UntoldEngine
import UntoldEngineXR
import UntoldSharePlay

final class CubeGame {
    private let frame: SharedFrame
    private let poses: SharePlayStateChannel<HeadPose>
    private let controls: CubeControls
    private var cubes: [UUID: EntityID] = [:]
    private var originMarker: EntityID?
    private var lastHead: simd_float4x4?
    private var lastSummaryUptime: TimeInterval = 0

    init(frame: SharedFrame, poses: SharePlayStateChannel<HeadPose>, controls: CubeControls) {
        self.frame = frame
        self.poses = poses
        self.controls = controls
    }

    func start() {
        setSceneReady(true)
        // A small cube at our ARKit origin: on the floor beneath where the
        // space opened. Proof that the engine renders before anyone joins.
        let marker = createEntity()
        setEntityMeshDirect(entityId: marker, meshes: BasicPrimitives.createCube(extent: 0.1), assetName: "Origin")
        translateTo(entityId: marker, position: SIMD3<Float>(0, 0.05, 0))
        originMarker = marker
    }

    func shutdown() {
        for cube in cubes.values { destroyEntity(entityId: cube) }
        cubes.removeAll()
        if let originMarker { destroyEntity(entityId: originMarker) }
        originMarker = nil
    }

    func update(deltaTime _: Float) {
        guard let xr = CubeHolder.shared.xr else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let head = xr.currentDevicePose {
            lastHead = head
            frame.updateDevicePose(head) // pairs with the system's pose of this device
            poses.publish(HeadPose(matrix: SharePlayMatrix(head))) // our local frame, as it is
            if now - lastSummaryUptime > 1 {
                lastSummaryUptime = now
                let p = head.columns.3
                controls.headSummary = String(format: "head (%.2f, %.2f, %.2f) m", p.x, p.y, p.z)
            }
        }
        if controls.takeMarkRequest() {
            markSpot()
        }
        if controls.takeCalibrationRequest() {
            calibrate()
        }
        placeCubes(now: now)
    }

    /// Mark my spot: our head pose, for the other player to stand on.
    private func markSpot() {
        guard let head = lastHead else {
            controls.lastCalibration = "no head pose yet"
            return
        }
        frame.publishMark(localPose: head)
        controls.lastCalibration = "marked this spot; step aside and let the other player stand on it, facing the same way"
    }

    /// Sync to the other player's mark: we stand on their spot, facing their
    /// way, so our head is where theirs was.
    private func calibrate() {
        guard let head = lastHead else {
            controls.lastCalibration = "no head pose yet"
            return
        }
        guard let participant = controls.others.first(where: { frame.mark(from: $0) != nil }) else {
            controls.lastCalibration = "no mark from the other player yet: they tap Mark first"
            return
        }
        let localPoint = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let localHeading = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        switch frame.calibrate(with: participant, localPoint: localPoint, localHeading: localHeading) {
        case let .solved(yaw, offset):
            controls.lastCalibration = String(format: "aligned with %@: yaw %.0f°, offset (%.2f, %.2f, %.2f) m", String(participant.uuidString.suffix(4)) as CVarArg, yaw, offset.x, offset.y, offset.z)
        case let .failed(reason):
            controls.lastCalibration = "alignment failed: \(reason)"
        }
    }

    private func placeCubes(now _: TimeInterval) {
        let latest = poses.latestAll()
        let present = Set(controls.others)
        for (participant, received) in latest where present.contains(participant) {
            let cube: EntityID
            if let existing = cubes[participant] {
                cube = existing
            } else {
                cube = createEntity()
                setEntityMeshDirect(entityId: cube, meshes: BasicPrimitives.createCube(extent: 0.2), assetName: "Head-\(participant.uuidString.prefix(8))")
                cubes[participant] = cube
            }
            let local = frame.toLocal(received.message.matrix.matrix, from: participant)
            translateTo(entityId: cube, position: SIMD3<Float>(local.columns.3.x, local.columns.3.y, local.columns.3.z))
            var rotation = local
            rotation.columns.3 = SIMD4<Float>(0, 0, 0, 1)
            rotateTo(entityId: cube, rotation: rotation)
        }
        for (participant, cube) in cubes where latest[participant] == nil || !present.contains(participant) {
            destroyEntity(entityId: cube)
            cubes[participant] = nil
        }
        controls.cubeCount = cubes.count
    }
}
