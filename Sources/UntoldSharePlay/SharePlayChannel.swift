//
//  SharePlayChannel.swift
//  UntoldSharePlay
//
//  Typed channels. A state channel carries what the next frame supersedes
//  (poses): unreliable, latest wins per sender, stale frames dropped by
//  sequence. An event channel carries what must arrive, in order (ignitions,
//  throws, snapshots, lobby commands): reliable. Both are lock-guarded and
//  usable from a render thread; the session's pump sends from the main actor.
//

import Foundation

/// A message that arrived, with what the envelope knew about it.
public struct SharePlayReceived<Message: Sendable>: Sendable {
    public let message: Message
    public let sender: UUID
    public let sequence: UInt32
    /// The sender's uptime when it sent the frame: compare only with the same
    /// sender's other frames.
    public let sentUptime: TimeInterval
    /// This device's uptime when the frame arrived.
    public let arrivalUptime: TimeInterval

    public init(message: Message, sender: UUID, sequence: UInt32, sentUptime: TimeInterval, arrivalUptime: TimeInterval) {
        self.message = message
        self.sender = sender
        self.sequence = sequence
        self.sentUptime = sentUptime
        self.arrivalUptime = arrivalUptime
    }

    /// Seconds since the frame arrived here.
    public var age: TimeInterval {
        ProcessInfo.processInfo.systemUptime - arrivalUptime
    }
}

/// An encoded frame waiting for the pump.
struct SharePlayOutgoingFrame: Sendable {
    let data: Data
    let recipients: SharePlayRecipients
}

/// What the session needs from a channel, whatever its message type.
protocol SharePlayChannelCore: AnyObject, Sendable {
    var id: String { get }
    var delivery: SharePlayDelivery { get }
    func takeOutgoing() -> [SharePlayOutgoingFrame]
    func receive(_ frame: WireFrame, from sender: UUID, arrivalUptime: TimeInterval)
    /// The participant left: what we hold from them is void.
    func forget(_ participant: UUID)
    /// The session ended.
    func reset()
}

/// Unreliable, latest wins per sender. `publish` from any thread, per frame;
/// `latest` and `latestAll` from any thread.
public final class SharePlayStateChannel<Message: Codable & Sendable>: SharePlayChannelCore, @unchecked Sendable {
    public let id: String
    let delivery: SharePlayDelivery = .unreliable

    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let diagnostics: SharePlayDiagnostics
    private var pending: (message: Message, recipients: SharePlayRecipients)?
    private var sequence: UInt32 = 0
    private var latestBySender: [UUID: SharePlayReceived<Message>] = [:]

    init(id: String, diagnostics: SharePlayDiagnostics) {
        self.id = id
        self.diagnostics = diagnostics
    }

    /// The state to send at the next pump tick; an earlier unsent one is dropped.
    public func publish(_ message: Message, to recipients: SharePlayRecipients = .all) {
        lock.withLock { pending = (message, recipients) }
    }

    public func latest(from sender: UUID) -> SharePlayReceived<Message>? {
        lock.withLock { latestBySender[sender] }
    }

    public func latestAll() -> [UUID: SharePlayReceived<Message>] {
        lock.withLock { latestBySender }
    }

    public func forget(_ participant: UUID) {
        lock.withLock { _ = latestBySender.removeValue(forKey: participant) }
    }

    func takeOutgoing() -> [SharePlayOutgoingFrame] {
        lock.withLock {
            guard let pending else { return [] }
            self.pending = nil
            do {
                let payload = try encoder.encode(pending.message)
                sequence &+= 1
                let frame = WireFrame(
                    kind: .state, channelID: id, sequence: sequence,
                    sentUptime: ProcessInfo.processInfo.systemUptime, payload: payload
                )
                let data = frame.encoded()
                diagnostics.noteSent(channel: id, bytes: data.count)
                return [SharePlayOutgoingFrame(data: data, recipients: pending.recipients)]
            } catch {
                diagnostics.noteEncodeFailure(channel: id, error)
                return []
            }
        }
    }

    func receive(_ frame: WireFrame, from sender: UUID, arrivalUptime: TimeInterval) {
        lock.withLock {
            if let existing = latestBySender[sender], !WireFrame.isNewer(frame.sequence, than: existing.sequence) {
                diagnostics.noteDroppedStale(channel: id)
                return
            }
            do {
                let message = try decoder.decode(Message.self, from: frame.payload)
                latestBySender[sender] = SharePlayReceived(
                    message: message, sender: sender, sequence: frame.sequence,
                    sentUptime: frame.sentUptime, arrivalUptime: arrivalUptime
                )
                diagnostics.noteReceived(channel: id, bytes: frame.payload.count)
            } catch {
                diagnostics.noteDecodeFailure(channel: id, error)
            }
        }
    }

    func reset() {
        lock.withLock {
            pending = nil
            latestBySender.removeAll()
        }
    }
}

/// Reliable, in order. `send` from any thread; `drain` from the thread that
/// handles the events, once per frame.
public final class SharePlayEventChannel<Message: Codable & Sendable>: SharePlayChannelCore, @unchecked Sendable {
    public let id: String
    let delivery: SharePlayDelivery = .reliable

    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let diagnostics: SharePlayDiagnostics
    private var outgoing: [(message: Message, recipients: SharePlayRecipients)] = []
    private var sequence: UInt32 = 0
    private var inbox: [SharePlayReceived<Message>] = []

    init(id: String, diagnostics: SharePlayDiagnostics) {
        self.id = id
        self.diagnostics = diagnostics
    }

    /// Queues the event; the pump sends the queue in order while the session
    /// is joined. Events queued with no session are dropped when one ends.
    public func send(_ message: Message, to recipients: SharePlayRecipients = .all) {
        lock.withLock { outgoing.append((message, recipients)) }
    }

    /// Everything that arrived since the last drain, in arrival order.
    public func drain() -> [SharePlayReceived<Message>] {
        lock.withLock {
            let events = inbox
            inbox.removeAll()
            return events
        }
    }

    /// Events queued and not sent yet.
    public var pendingCount: Int {
        lock.withLock { outgoing.count }
    }

    public func forget(_: UUID) {}

    func takeOutgoing() -> [SharePlayOutgoingFrame] {
        lock.withLock {
            guard !outgoing.isEmpty else { return [] }
            let queued = outgoing
            outgoing.removeAll()
            var frames: [SharePlayOutgoingFrame] = []
            frames.reserveCapacity(queued.count)
            for item in queued {
                do {
                    let payload = try encoder.encode(item.message)
                    sequence &+= 1
                    let frame = WireFrame(
                        kind: .event, channelID: id, sequence: sequence,
                        sentUptime: ProcessInfo.processInfo.systemUptime, payload: payload
                    )
                    let data = frame.encoded()
                    diagnostics.noteSent(channel: id, bytes: data.count)
                    frames.append(SharePlayOutgoingFrame(data: data, recipients: item.recipients))
                } catch {
                    diagnostics.noteEncodeFailure(channel: id, error)
                }
            }
            return frames
        }
    }

    func receive(_ frame: WireFrame, from sender: UUID, arrivalUptime: TimeInterval) {
        lock.withLock {
            do {
                let message = try decoder.decode(Message.self, from: frame.payload)
                inbox.append(SharePlayReceived(
                    message: message, sender: sender, sequence: frame.sequence,
                    sentUptime: frame.sentUptime, arrivalUptime: arrivalUptime
                ))
                diagnostics.noteReceived(channel: id, bytes: frame.payload.count)
            } catch {
                diagnostics.noteDecodeFailure(channel: id, error)
            }
        }
    }

    func reset() {
        lock.withLock {
            outgoing.removeAll()
            inbox.removeAll()
        }
    }
}

/// The channels by id; routes incoming frames and collects outgoing ones.
/// Lock-guarded so the receive loops run off the main actor.
final class SharePlayRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [String: any SharePlayChannelCore] = [:]

    func channel(id: String) -> (any SharePlayChannelCore)? {
        lock.withLock { channels[id] }
    }

    func register(_ channel: any SharePlayChannelCore) {
        lock.withLock { channels[channel.id] = channel }
    }

    func route(_ incoming: SharePlayIncoming, diagnostics: SharePlayDiagnostics) {
        let frame: WireFrame
        do {
            frame = try WireFrame.decode(incoming.data)
        } catch {
            diagnostics.noteUndecodableFrame(error)
            return
        }
        guard let channel = channel(id: frame.channelID) else {
            diagnostics.noteUnrouted(channel: frame.channelID)
            return
        }
        channel.receive(frame, from: incoming.sender, arrivalUptime: ProcessInfo.processInfo.systemUptime)
    }

    func takeOutgoing(delivery: SharePlayDelivery) -> [SharePlayOutgoingFrame] {
        let matching = lock.withLock { channels.values.filter { $0.delivery == delivery } }
        return matching.flatMap { $0.takeOutgoing() }
    }

    func forget(participant: UUID) {
        let all = lock.withLock { Array(channels.values) }
        for channel in all { channel.forget(participant) }
    }

    func resetAll() {
        let all = lock.withLock { Array(channels.values) }
        for channel in all { channel.reset() }
    }
}
