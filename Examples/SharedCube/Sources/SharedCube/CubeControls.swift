//
//  CubeControls.swift
//  SharedCube
//

import Foundation
import simd

/// What the window asks of the game thread, and what the game reports back.
/// Lock-guarded: the game runs on the render thread.
final class CubeControls: @unchecked Sendable {
    private let lock = NSLock()
    private var calibrationRequested = false
    private var lastCalibrationStorage = "not calibrated"
    private var headSummaryStorage = "no head pose yet"
    private var cubeCountStorage = 0

    /// The window's Sync button: both players stand on one spot, facing the
    /// same way, then one taps Sync.
    func requestCalibration() {
        lock.withLock { calibrationRequested = true }
    }

    func takeCalibrationRequest() -> Bool {
        lock.withLock {
            let requested = calibrationRequested
            calibrationRequested = false
            return requested
        }
    }

    var lastCalibration: String {
        get { lock.withLock { lastCalibrationStorage } }
        set { lock.withLock { lastCalibrationStorage = newValue } }
    }

    var headSummary: String {
        get { lock.withLock { headSummaryStorage } }
        set { lock.withLock { headSummaryStorage = newValue } }
    }

    var cubeCount: Int {
        get { lock.withLock { cubeCountStorage } }
        set { lock.withLock { cubeCountStorage = newValue } }
    }
}
