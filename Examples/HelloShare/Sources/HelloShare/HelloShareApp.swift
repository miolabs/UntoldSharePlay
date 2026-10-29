//
//  HelloShareApp.swift
//  HelloShare
//
//  The plugin's smallest game: a window, no immersive space, no engine.
//  Every participant counts taps and sees everyone's count (a state channel:
//  the latest count wins), and a wave is heard by all (an event channel:
//  reliable, in order). Start SharePlay from a FaceTime call or with people
//  nearby; the simulator builds it, but has no SharePlay.
//

import GroupActivities
import SwiftUI
import UntoldSharePlay

/// The one type the game declares. The identifier is what the system matches
/// sessions on, so keep it stable.
struct HelloShareActivity: GroupActivity {
    static let activityIdentifier = "com.miolabs.untold.helloshare.room"

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "Hello, Share"
        metadata.type = .generic
        return metadata
    }
}

// The wire types: plain Codable. No sequence or timestamp fields; the
// plugin's envelope carries them.

struct TapCount: Codable, Sendable {
    var taps: Int
}

enum Shout: Codable, Sendable {
    case wave
}

@MainActor
@Observable
final class HelloModel {
    let session: SharePlaySession
    let counts: SharePlayStateChannel<TapCount>
    let shouts: SharePlayEventChannel<Shout>
    var taps = 0
    /// Everyone else's count, read from the channel on each pump tick.
    var others: [(id: UUID, taps: Int)] = []
    var waves: [String] = []

    init() {
        session = SharePlaySession(HelloShareActivity()) {
            $0.groupImmersiveSpace = false // a window is enough: no shared space
            $0.stateRate = 10 // ten sends a second is plenty for a counter
        }
        counts = session.stateChannel(TapCount.self) // unreliable, latest wins per sender
        shouts = session.eventChannel(Shout.self) // reliable, in order
        session.addTickHandler { [weak self] in self?.collect() }
    }

    func tap() {
        taps += 1
        counts.publish(TapCount(taps: taps)) // the next tick sends it; an unsent earlier one is dropped
    }

    func wave() {
        shouts.send(.wave)
    }

    /// Once per pump tick while joined, on the main actor: what arrived.
    private func collect() {
        others = counts.latestAll()
            .map { (id: $0.key, taps: $0.value.message.taps) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for shout in shouts.drain() {
            waves.append("\(shout.sender.uuidString.prefix(4)) waved")
        }
    }
}

@main
struct HelloShareApp: App {
    @State private var model = HelloModel()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("Hello, Share").font(.largeTitle).bold()
                SharePlayStatusView(model.session) // Start SharePlay / Leave, the state, who is here
                HStack {
                    Button("Tap · \(model.taps)") { model.tap() }
                    Button("Wave") { model.wave() }
                }
                ForEach(model.others, id: \.id) { other in
                    Text("\(other.id.uuidString.prefix(4)) · \(other.taps) taps")
                }
                ForEach(Array(model.waves.suffix(5).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption)
                }
                Spacer()
            }
            .padding(28)
            .task { model.session.startObserving() } // once: every session the system hands the app is joined
        }
        .defaultSize(width: 480, height: 560)
    }
}
