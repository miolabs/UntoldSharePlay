//
//  CubeHolder.swift
//  SharedCube
//
//  Retains the XR system and the game while the space is open (the engine's
//  XRHolder pattern), and reports the space's life to the coordinator.
//

import Foundation
import UntoldEngineXR

final class CubeHolder: @unchecked Sendable {
    static let shared = CubeHolder()
    var xr: UntoldEngineXR?
    var game: CubeGame?
    var renderThread: Thread?
}
