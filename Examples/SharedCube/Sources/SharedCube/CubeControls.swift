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
    private var markRequested = false
    private var calibrationRequested = false
    private var lastCalibrationStorage = "not aligned"
    private var headSummaryStorage = "no head pose yet"
    private var cubeCountStorage = 0
    private var othersStorage: [UUID] = []

    /// Mark my spot: our head pose goes to the others as the spot to stand on.
    func requestMark() {
        lock.withLock { markRequested = true }
    }

    func takeMarkRequest() -> Bool {
        lock.withLock {
            let requested = markRequested
            markRequested = false
            return requested
        }
    }

    /// Sync to the other player's mark: we stand on it, facing the same way.
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

    /// The other participants, copied here on the main actor whenever the
    /// session changes, so the render thread never touches the session.
    var others: [UUID] {
        get { lock.withLock { othersStorage } }
        set { lock.withLock { othersStorage = newValue } }
    }
}
