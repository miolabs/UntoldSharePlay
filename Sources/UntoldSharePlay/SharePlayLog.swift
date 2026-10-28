//
//  SharePlayLog.swift
//  UntoldSharePlay
//

import Foundation

/// The plugin's log lines, prefixed `[SharePlay]` like the games' own.
public enum SharePlayLog {
    /// Off silences every line of the plugin.
    public nonisolated(unsafe) static var isEnabled = true

    static func info(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("[SharePlay] \(message())")
    }
}
