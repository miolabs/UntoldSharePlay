//
//  CubeAnchors.swift
//  SharedCube
//
//  The engine's XR runtime as the plugin's world-anchor host: the shared
//  world anchors of visionOS 26, the system's way of handing the room map it
//  built when both players looked at the same point to an app that renders
//  its own space. Needs the engine's world-anchor API (the branch
//  feature/xr_shared_world_anchors, CoolSaber's); project.yml points at it.
//

import Foundation
import simd
import UntoldEngineXR
import UntoldSharePlay

extension UntoldEngineXR: @retroactive @unchecked Sendable {}

extension UntoldEngineXR: SharePlayWorldAnchorHost {
    public func addSharedWorldAnchor(localFromAnchor: simd_float4x4) -> UUID? {
        addWorldAnchor(originFromAnchorTransform: localFromAnchor, sharedWithNearbyParticipants: true)
    }

    public func addWorldAnchorObserver(_ handler: @escaping @Sendable (SharePlayAnchorUpdate) -> Void) -> UUID {
        addWorldAnchorObserver { (update: XRWorldAnchorUpdate) in
            let event: SharePlayAnchorUpdate.Event
            switch update.event {
            case .added: event = .added
            case .updated: event = .updated
            case .removed: event = .removed
            }
            handler(SharePlayAnchorUpdate(
                id: update.id,
                localFromAnchor: update.originFromAnchorTransform,
                isTracked: update.isTracked,
                isShared: update.isSharedWithNearbyParticipants,
                isOwn: update.isOwn,
                event: event
            ))
        }
    }
}
