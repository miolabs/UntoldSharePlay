//
//  SharedCubeActivity.swift
//  SharedCube
//

import Foundation
import GroupActivities
import UntoldSharePlay

/// The example's activity: the one type a game declares. The identifier is
/// what the system matches sessions on.
struct SharedCubeActivity: GroupActivity {
    static let activityIdentifier = "com.miolabs.untold.sharedcube.room"

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "Shared Cube"
        metadata.subtitle = "See where everyone is"
        metadata.type = .generic
        return metadata
    }
}

/// Our head pose, in our own local frame; the receiver maps it.
struct HeadPose: Codable, Sendable {
    var matrix: SharePlayMatrix
}
