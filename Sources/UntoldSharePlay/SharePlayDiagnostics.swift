//
//  SharePlayDiagnostics.swift
//  UntoldSharePlay
//
//  Counters per channel for the window's diagnostics row and the tests:
//  what was sent and received, what was dropped as stale, what failed to
//  encode or decode, what arrived for a channel nobody registered.
//

import Foundation

public final class SharePlayDiagnostics: @unchecked Sendable {
    public struct ChannelCounters: Sendable, Equatable {
        public var sentFrames = 0
        public var sentBytes = 0
        public var receivedFrames = 0
        public var receivedBytes = 0
        public var droppedStale = 0
        public var encodeFailures = 0
        public var decodeFailures = 0

        public init() {}
    }

    public struct Snapshot: Sendable, Equatable {
        public var channels: [String: ChannelCounters] = [:]
        public var unroutedFrames = 0
        public var undecodableFrames = 0
        public var sendFailures = 0

        public init() {}
    }

    private let lock = NSLock()
    private var current = Snapshot()
    private var reportedDecodeFailure: Set<String> = []

    public init() {}

    public func snapshot() -> Snapshot {
        lock.withLock { current }
    }

    public func reset() {
        lock.withLock {
            current = Snapshot()
            reportedDecodeFailure.removeAll()
        }
    }

    /// One line for a diagnostics row: `poses ↑120 ↓118 stale 2 · events ↑3 ↓4`.
    public func summary() -> String {
        let snapshot = snapshot()
        var parts = snapshot.channels.keys.sorted().map { id -> String in
            let counters = snapshot.channels[id]!
            var part = "\(id) ↑\(counters.sentFrames) ↓\(counters.receivedFrames)"
            if counters.droppedStale > 0 { part += " stale \(counters.droppedStale)" }
            if counters.decodeFailures > 0 { part += " undecodable \(counters.decodeFailures)" }
            return part
        }
        if snapshot.unroutedFrames > 0 { parts.append("unrouted \(snapshot.unroutedFrames)") }
        if snapshot.sendFailures > 0 { parts.append("send failures \(snapshot.sendFailures)") }
        return parts.isEmpty ? "no traffic" : parts.joined(separator: " · ")
    }

    func noteSent(channel: String, bytes: Int) {
        lock.withLock {
            current.channels[channel, default: ChannelCounters()].sentFrames += 1
            current.channels[channel, default: ChannelCounters()].sentBytes += bytes
        }
    }

    func noteReceived(channel: String, bytes: Int) {
        lock.withLock {
            current.channels[channel, default: ChannelCounters()].receivedFrames += 1
            current.channels[channel, default: ChannelCounters()].receivedBytes += bytes
        }
    }

    func noteDroppedStale(channel: String) {
        lock.withLock { current.channels[channel, default: ChannelCounters()].droppedStale += 1 }
    }

    func noteEncodeFailure(channel: String, _ error: any Error) {
        lock.withLock { current.channels[channel, default: ChannelCounters()].encodeFailures += 1 }
        SharePlayLog.info("channel \(channel): could not encode a message: \(error)")
    }

    func noteDecodeFailure(channel: String, _ error: any Error) {
        let first: Bool = lock.withLock {
            current.channels[channel, default: ChannelCounters()].decodeFailures += 1
            return reportedDecodeFailure.insert(channel).inserted
        }
        if first {
            SharePlayLog.info("channel \(channel): could not decode a message (reported once): \(error)")
        }
    }

    func noteUnrouted(channel: String) {
        let first: Bool = lock.withLock {
            current.unroutedFrames += 1
            return reportedDecodeFailure.insert("unrouted:" + channel).inserted
        }
        if first {
            SharePlayLog.info("frames arrive for channel \(channel), which this side has not registered (reported once)")
        }
    }

    func noteUndecodableFrame(_ error: any Error) {
        let count: Int = lock.withLock {
            current.undecodableFrames += 1
            return current.undecodableFrames
        }
        if count == 1 {
            SharePlayLog.info("a frame could not be decoded (reported once): \(error)")
        }
    }

    func noteSendFailure() {
        lock.withLock { current.sendFailures += 1 }
    }
}
