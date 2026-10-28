//
//  SharePlayStatusView.swift
//  UntoldSharePlay
//
//  The control-window row every game had: Start, Leave, the state and the
//  participants. Restyle it or write your own from the session's properties.
//

#if canImport(SwiftUI)
    import SwiftUI

    @MainActor
    public struct SharePlayStatusView: View {
        private let session: SharePlaySession

        public init(_ session: SharePlaySession) {
            self.session = session
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.statusMessage)
                    .font(.callout)
                HStack {
                    Button {
                        Task { await session.start() }
                    } label: {
                        Label("Start SharePlay", systemImage: "shareplay")
                    }
                    .disabled(session.state != .idle)
                    Button(role: .destructive) {
                        session.leave()
                    } label: {
                        Label("Leave", systemImage: "xmark.circle")
                    }
                    .disabled(session.state == .idle)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        private var detail: String {
            guard session.state == .joined else { return "" }
            let others = session.others
            let nearby = others.filter(\.isNearby).count
            let spatial = others.filter(\.isSpatial).count
            var parts = ["\(others.count) other participant\(others.count == 1 ? "" : "s")"]
            parts.append("spatial \(session.isSpatial ? "yes" : "no") (\(spatial) remote)")
            parts.append("nearby \(nearby)")
            if session.hostID != nil {
                parts.append(session.isHost ? "host: this device" : "host: another device")
            }
            parts.append(session.diagnostics.summary())
            return parts.joined(separator: " · ")
        }
    }
#endif
