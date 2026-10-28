//
//  WireFrame.swift
//  UntoldSharePlay
//
//  The envelope around every message on the wire: the channel it belongs to,
//  the sender's sequence on that channel and the sender's uptime, then the
//  payload the channel encoded. A fixed little-endian header, so the payload
//  travels as it is (no base64 inside JSON).
//

import Foundation

public struct WireFrame: Equatable, Sendable {
    public static let version: UInt8 = 1

    public enum Kind: UInt8, Sendable {
        case state = 0
        case event = 1
    }

    public enum DecodingError: Error, Equatable {
        case tooShort
        case unsupportedVersion(UInt8)
        case badKind(UInt8)
        case badChannelID
    }

    public var kind: Kind
    public var channelID: String
    public var sequence: UInt32
    /// The sender's `systemUptime` when the frame was built: for staleness on
    /// the sender's own clock, never for anything across devices.
    public var sentUptime: Double
    public var payload: Data

    public init(kind: Kind, channelID: String, sequence: UInt32, sentUptime: Double, payload: Data) {
        self.kind = kind
        self.channelID = channelID
        self.sequence = sequence
        self.sentUptime = sentUptime
        self.payload = payload
    }

    /// Header: version u8, kind u8, channel id length u16, channel id,
    /// sequence u32, sent uptime f64; then the payload. 16 bytes plus the id.
    public func encoded() -> Data {
        let id = Data(channelID.utf8)
        var data = Data()
        data.reserveCapacity(16 + id.count + payload.count)
        data.append(Self.version)
        data.append(kind.rawValue)
        Self.append(UInt16(truncatingIfNeeded: id.count), to: &data)
        data.append(id)
        Self.append(sequence, to: &data)
        Self.append(sentUptime.bitPattern, to: &data)
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> WireFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { throw DecodingError.tooShort }
        guard bytes[0] == version else { throw DecodingError.unsupportedVersion(bytes[0]) }
        guard let kind = Kind(rawValue: bytes[1]) else { throw DecodingError.badKind(bytes[1]) }
        let idLength = Int(read(UInt16.self, from: bytes, at: 2))
        let idEnd = 4 + idLength
        guard bytes.count >= idEnd + 12 else { throw DecodingError.tooShort }
        guard let channelID = String(bytes: bytes[4 ..< idEnd], encoding: .utf8) else {
            throw DecodingError.badChannelID
        }
        let sequence = read(UInt32.self, from: bytes, at: idEnd)
        let sentUptime = Double(bitPattern: read(UInt64.self, from: bytes, at: idEnd + 4))
        let payload = Data(bytes[(idEnd + 12)...])
        return WireFrame(kind: kind, channelID: channelID, sequence: sequence, sentUptime: sentUptime, payload: payload)
    }

    /// Newer-than with wrap-around: a sequence that restarted after
    /// `UInt32.max` counts as newer than the ones just below the wrap.
    public static func isNewer(_ sequence: UInt32, than reference: UInt32) -> Bool {
        sequence != reference && (sequence &- reference) < UInt32.max / 2
    }

    private static func append(_ value: some FixedWidthInteger, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_: T.Type, from bytes: [UInt8], at offset: Int) -> T {
        var value: T = 0
        for index in 0 ..< MemoryLayout<T>.size {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        return value
    }
}
