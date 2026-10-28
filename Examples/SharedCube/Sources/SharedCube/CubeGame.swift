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
            poses.publish(HeadPose(matrix: SharePlayMatrix(frame.toShared(head))))
            if now - lastSummaryUptime > 1 {
                lastSummaryUptime = now
                let p = head.columns.3
                controls.headSummary = String(format: "head (%.2f, %.2f, %.2f) m", p.x, p.y, p.z)
            }
        }
        if controls.takeCalibrationRequest() {
            calibrate()
        }
        placeCubes(now: now)
    }

    /// Both players on one spot, facing the same way: our head is their head.
    private func calibrate() {
        guard let head = lastHead else {
            controls.lastCalibration = "no head pose yet"
            return
        }
        let latest = poses.latestAll().filter { $0.value.age < 2 }
        guard let (participant, received) = latest.min(by: { $0.value.arrivalUptime > $1.value.arrivalUptime }) else {
            controls.lastCalibration = "no fresh head pose from anyone"
            return
        }
        let remote = received.message.matrix.matrix
        let localPoint = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let localHeading = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        let remotePoint = SIMD3<Float>(remote.columns.3.x, remote.columns.3.y, remote.columns.3.z)
        let remoteHeading = -SIMD3<Float>(remote.columns.2.x, remote.columns.2.y, remote.columns.2.z)
        switch frame.calibrate(with: participant, localPoint: localPoint, localHeading: localHeading, remotePoint: remotePoint, remoteHeading: remoteHeading) {
        case let .solved(yaw, offset):
            controls.lastCalibration = String(format: "calibrated with %@: yaw %.0f°, offset (%.2f, %.2f, %.2f) m", participant.uuidString.prefix(8) as CVarArg, yaw, offset.x, offset.y, offset.z)
        case let .failed(reason):
            controls.lastCalibration = "calibration failed: \(reason)"
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
