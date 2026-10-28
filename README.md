# UntoldSharePlay

SharePlay for [Untold Engine](https://github.com/untoldengine/UntoldEngine) games on Apple Vision Pro, as one plugin: the group session (a FaceTime call, or people nearby on visionOS 26), typed channels for game state and events, the participants and an optional host, the shared coordinate frame between headsets, and the immersive-space coordinator. A game keeps three things of its own: its `GroupActivity`, its wire types, and what the messages do.

It comes from three hand-written copies of the same code: CoolSaber's duel in [UntoldArcade](https://github.com/untoldengine/UntoldArcade), the RealityKit presenter spike, and the plan of the Oche darts game. The design note is `docs/proposals/SharePlayPlugin.md` in the engine repository.

## Status

| Stage | What | State |
|---|---|---|
| 1 | The core: session, channels, participants and host election, status view, diagnostics, the transport seam with the GroupActivities and loopback transports; tests on macOS | **built** (this branch) |
| 2 | The shared frame (displacement, shared world anchors, manual calibration, fallback), the immersive-space coordinator, the `UntoldSharePlayXR` bridge, a `SharedCube` example | next |
| 3 | CoolSaber on the plugin (two headsets) | |
| 4 | Oche's SharePlay milestone on the core (RealityKit, no engine) | |
| 5 | `untoldengine create --shareplay`, the engine docs page | |
| 6 | An editor plugin: the session options in the Inspector, the participants' spots drawn in the viewport | |

## Products

| Product | Depends on | For |
|---|---|---|
| `UntoldSharePlay` | GroupActivities, SwiftUI | every game, including RealityKit ones: no engine dependency |
| `UntoldSharePlayXR` (stage 2) | `UntoldEngineXR` | games rendering through the engine's XR runtime: shared world anchors and the immersive-space displacement |

Platforms: visionOS 2, iOS 17, macOS 14 (the engine's minimums). The visionOS 26 API (nearby participants, remote spatial states) is used when available and reported as absent before. The system coordinator exists only on visionOS; on macOS and iOS the session carries messages and participants only.

## Install

```swift
// Package.swift
.package(url: "https://github.com/miolabs/UntoldSharePlay.git", branch: "develop"),
// target dependencies
.product(name: "UntoldSharePlay", package: "UntoldSharePlay"),
```

The app needs the `com.apple.developer.group-session` entitlement. Nothing in `Info.plist`.

## Use

```swift
import GroupActivities
import UntoldSharePlay

// 1. The activity: the one type the game declares. The identifier is what
//    the system matches sessions on, so the plugin never ships one.
struct DuelActivity: GroupActivity {
    static let activityIdentifier = "com.example.duel"
    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "Duel"
        metadata.type = .generic
        return metadata
    }
}

// 2. Wire types: plain Codable. No sequence or timestamp fields; the plugin's
//    envelope carries them.
struct Poses: Codable, Sendable { var head: simd_float4x4; var hands: [simd_float4x4] }
enum DuelEvent: Codable, Sendable { case hit(at: SIMD3<Float>) }

// 3. The session, once, on the main actor.
@MainActor let session = SharePlaySession(DuelActivity()) {
    $0.groupImmersiveSpace = true          // Personas and one shared frame
    $0.spatialTemplate = .conversational   // .sideBySide, .surround, .none
    $0.stateRate = 45                      // Hz of the pump
    $0.hostElection = .none                // .lowestParticipantID for a host-authoritative game
}
let poses = session.stateChannel(Poses.self)        // unreliable, latest wins per sender
let events = session.eventChannel(DuelEvent.self)   // reliable, in order
session.startObserving()                            // once at launch: joins every session the system hands the app

// 4. The window: Start / Leave, the state, the participants.
SharePlayStatusView(session)

// 5. Per frame, from the render thread or a RealityView update.
poses.publish(Poses(head: head, hands: hands))
for (participant, received) in poses.latestAll() where received.age < 0.5 {
    avatars[participant].place(received.message)
}
for event in events.drain() {
    if case let .hit(point) = event.message { spark(at: point, from: event.sender) }
}

// 6. Who is here, and who decides.
session.participants      // in join order, the local one included (isLocal, isNearby, isSpatial)
session.isHost            // with .lowestParticipantID: the same answer on every device
session.addEventHandler { event in
    switch event {
    case .participantJoined(let id): snapshots.send(currentSnapshot, to: .only([id]))
    case .hostChanged: if session.isHost { snapshots.send(currentSnapshot) }
    default: break
    }
}
```

Starting: `await session.start()` runs the system's share flow (`prepareForActivation`, then `activate`) and reports `.started`, `.notAvailable` (no call, nobody nearby), `.cancelled` or `.failed`. The session itself arrives through `startObserving()`, as it does when someone else starts it from the FaceTime call or the window bar.

Until stage 2 lands, poses cross the wire in each device's own frame; the shared frame (the system's displacement, shared world anchors for nearby participants, the manual calibration) is what stage 2 adds, with `session.frame.toShared` and `toLocal(from:)`.

### Threads

The session and the status view are main-actor and observable. The channels and the diagnostics are lock-guarded and usable from a render thread: `publish`, `latest`, `latestAll`, `send`, `drain`. The pump runs on the main actor at `stateRate` and sends what the channels queued while the session is joined. Nothing in the plugin uses an actor on the frame path.

### What the plugin takes care of (the lessons of the three copies)

1. The messengers and their receive loops exist before `join()`, so no early frame is lost.
2. Frames are sent only once the session is `.joined`; events queued earlier go then.
3. `sessions()` emits a session once; its state and participants are observed per session.
4. The local participant is subtracted where it matters; a participant leaving voids what they sent.
5. Unreliable frames out of order are dropped by sequence, with wrap-around; the sender's uptime is only compared with the same sender's.
6. `prepareForActivation()` runs before `activate()`: "not available" is a state, not an error.
7. Nearby and spatial flags come from the visionOS 26 API when it exists, and are false before.
8. The group's immersion style is reported as `.notRequested`, `.requested(style)` or `.ended`, for the space coordinator of stage 2.

### Testing

```sh
swift test
```

The core is tested on macOS through `LoopbackTransport`: a `LoopbackHub` makes one transport per simulated participant, a session for all of them on the first `start()`, and routes frames between the joined ones with optional loss, reordering and delay on the unreliable path. The same hub runs two instances of a game on one Mac. `LoopbackSession.simulateSpatial` stands in for the system coordinator.

GroupActivities itself is exercised only on devices (the simulator has no SharePlay).

## Layout

| Path | What it is |
|---|---|
| `Sources/UntoldSharePlay/SharePlayTransport.swift` | The seam: `SharePlayTransport`, `SharePlayTransportSession`, `SharePlayTransportChannel` and the value types they exchange. |
| `GroupActivitiesTransport.swift` | The real transport: `Activity.sessions()`, two messengers per session, the system coordinator on visionOS. |
| `LoopbackTransport.swift` | The in-process transport for tests and for two instances on one Mac. |
| `SharePlaySession.swift` | The session: state, participants, host, channels, spatial reports, the pump, the events. |
| `SharePlayChannel.swift` | `SharePlayStateChannel`, `SharePlayEventChannel`, the router. |
| `WireFrame.swift` | The envelope: channel id, sequence, sent uptime, payload. |
| `SharePlayParticipants.swift` | `SharePlayParticipant`, `HostElection`. |
| `SharePlayDiagnostics.swift`, `SharePlayLog.swift` | Counters per channel and the `[SharePlay]` log lines (`SharePlayLog.isEnabled`). |
| `SharePlayStatusView.swift` | The control-window row. |

## Compatibility

| Plugin | Untold Engine |
|---|---|
| 0.1.x (core only) | none required |

## License

MIT, see `LICENSE`.
