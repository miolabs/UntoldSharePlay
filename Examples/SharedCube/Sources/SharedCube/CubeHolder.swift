//
//  CubeHolder.swift
//  SharedCube
//
//  Retains the XR system and the game while the space is open (the engine's
//  XRHolder pattern), and releases them when the space closes.
//

import Foundation
import UntoldEngine
import UntoldEngineXR

final class CubeHolder: @unchecked Sendable {
    static let shared = CubeHolder()
    var xr: UntoldEngineXR?
    var game: CubeGame?
    var renderThread: Thread?

    /// Releases the session the system closed (the crown, the group's request,
    /// a cycle on the join). Once `runLoop()` has returned no frame runs again,
    /// and the engine's deferred teardown (`shutdownUntoldEngineXR`, whose
    /// completion fires from a frame's finalize pass) would never complete: the
    /// holder would keep the old session and the space could not reopen. So it
    /// is released here and now, CoolBowling's pattern: the entities are marked
    /// and finalized by the next session's first frames. Main actor.
    @MainActor
    func release() {
        if let xr {
            setRendering(.extensions(.removeAll))
            xr.clearSpatialInput()
            xr.stop()
        }
        destroyAllEntities()
        xr = nil
        game = nil
        renderThread = nil
    }
}
