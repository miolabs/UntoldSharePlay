# UntoldSharePlay

SharePlay for [Untold Engine](https://github.com/untoldengine/UntoldEngine) games on Apple Vision Pro, as one plugin: the group session (a FaceTime call, or people nearby on visionOS 26), typed channels for game state and events, the participants and an optional host, the shared coordinate frame between headsets, and the immersive-space coordinator. A game keeps three things of its own: its `GroupActivity`, its wire types, and what the messages do.

It comes from three hand-written copies of the same code: CoolSaber's duel in [UntoldArcade](https://github.com/untoldengine/UntoldArcade), the RealityKit presenter spike, and the plan of the Oche darts game. The design note is `docs/proposals/SharePlayPlugin.md` in the engine repository.

## Status

| Stage | What | State |
|---|---|---|
| 1 | The core: session, channels, participants and host election, status view, diagnostics, the transport seam with the GroupActivities and loopback transports; tests on macOS | **built** (PR #1) |
| 2 | The shared frame (the system's displacement, shared world anchors, the manual calibration, the fallback stage), the immersive-space coordinator, the displacement modifier for a CompositorLayer, the `SharedCube` example | **built** (this branch); the engine side of the shared anchors waits for the engine's world-anchor API |
| 2b | The headset test of stages 1 and 2 with `Examples/SharedCube` (nearby, FaceTime, alone): the protocol is in the example's README | **next**, before anything else |
| 3 | CoolSaber on the plugin (two headsets) | after the engine's world-anchor API ships |
| 4 | Oche's SharePlay milestone on the core (RealityKit, no engine) | |
| 5 | `untoldengine create --shareplay`, the engine docs page | **built** (engine fork PR miolabs/UntoldEngine#86) |
| 6 | An editor plugin: the session options in the Inspector, the participants' spots drawn in the viewport | after the headset test |

## Products

| Product | Depends on | For |
|---|---|---|
| `UntoldSharePlay` | GroupActivities, SwiftUI, Spatial | every game, including RealityKit ones: no engine dependency. Holds the frame, the anchor tracking behind `SharePlayWorldAnchorHost`, the coordinator and the `CompositorLayer` modifier (visionOS 26) |
| `UntoldSharePlayXR` (pending) | `UntoldEngineXR` | the engine's conformance to `SharePlayWorldAnchorHost`, once the engine's shared world-anchor API ships (today it exists only on CoolSaber's branch) |

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

### The shared frame

Two frames: *shared*, the group's immersive-space frame, identical on every spatial or nearby device, which is what goes on the wire; and *local*, the frame the game simulates in: ARKit's world frame on the engine path, the scene's frame on a RealityView space (already the shared frame). Per remote participant one mapping is in force, by precedence: the manual calibration the players solved, then the participant's shared world anchor (nearby), then the system's displacement (spatial with us, or nearby), then a fallback stage pose (remote and not spatial: a row 2 m ahead, facing us, 0.8 m apart, in join order).

```swift
// Before publishing: our local pose in the shared frame.
poses.publish(Poses(head: session.frame.toShared(head)))
// After receiving: the participant's wire pose in our local frame.
let local = session.frame.toLocal(received.message.head, from: participant)
session.frame.alignment(of: participant)      // .manual, .sharedAnchor, .systemDisplacement, .fallbackStage
session.frame.summary(of: participant)        // for a diagnostics row
session.frame.fallbackStage = .init(distance: 2, spacing: 0.8)

// A CompositorLayer app feeds the system's displacement (visionOS 26):
CompositorLayer(configuration: config) { layerRenderer in ... }
    .sharePlayFrame(session)
// A RealityView app does nothing: scene coordinates are the shared frame;
// ARKit-sourced poses (hands, anchors) go through session.frame.sharedFromLocal.

// The manual calibration: both players touch one point and face one way.
// `remotePoint` and `remoteHeading` are what the participant published, raw.
switch session.frame.calibrate(with: participant, localPoint: p, localHeading: h, remotePoint: rp, remoteHeading: rh) {
case let .solved(yawDegrees, offset): ...   // installed here, the inverse sent to the other side
case let .failed(reason): ...               // "hold the headings level"
}
session.frame.setNudge(SIMD2(side, forward), for: participant)   // fine tune; re-sent once it rests 0.3 s
```

Shared world anchors (visionOS 26, nearby participants): the session places this device's anchor at its origin as soon as someone nearby is in the session, announces its id on its own channel, and maps every other participant's anchor into the frame. This needs a world-tracking host: `session.anchors.attach(host)` with a `SharePlayWorldAnchorHost` (four methods: add a shared anchor, remove it, observe updates, stop observing). The engine's XR runtime conforms once its world-anchor API ships; until then a game on CoolSaber's engine branch writes the 20-line conformance itself.

### The immersive space

`ImmersiveSpaceCoordinator` is the one place that opens and dismisses the space (visionOS allows one request at a time): at most one in flight, an open during the engine's teardown deferred until `spaceDidTearDown()`, one retry after an error, a space presented without a renderer recovered by a dismiss, and `joinGroup`, which cycles an open space because a space opened before the session joined stays private.

```swift
let space = ImmersiveSpaceCoordinator(id: "Arena")          // tracksTeardown: false for a RealityView space
space.bind(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
session.drive(space)      // opens on the group's request, cycles on the join, dismisses when the group leaves
// From the CompositorLayer closure: space.spaceDidStart(rendering: true)
// After xr.runLoop() returns, on the main actor: release the engine, then space.spaceDidTearDown()
```

Release the engine synchronously after `runLoop()` returns (stop it, clear the
spatial input, `destroyAllEntities()` without a completion, drop the holder's
references), as `Examples/SharedCube` and CoolBowling do. Do not wait for
`shutdownUntoldEngineXR`'s completion there: it fires from a frame's finalize
pass, and no frame runs once the loop has returned, so a game with entities
would never report the teardown and the space could never reopen.

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
8. The group's immersion style is reported as `.notRequested`, `.requested(style)` or `.ended`; `drive` turns it into open, cycle and dismiss.
9. The system's displacement is ARKit-from-shared: the sender strips its own, the receiver applies its own; the device anchor and the controllers stay in the un-displaced ARKit frame.
10. Shared world anchors are nearby-only and ARKit does not say who placed one, so each device announces its anchor's id; with exactly one nearby participant an unannounced anchor is theirs.
11. A participant leaving voids every mapping solved for them; a session ending resets the frame.

### Testing

```sh
swift test
```

The core (50 tests) is tested on macOS through `LoopbackTransport`: a `LoopbackHub` makes one transport per simulated participant, a session for all of them on the first `start()`, and routes frames between the joined ones with optional loss, reordering and delay on the unreliable path. The same hub runs two instances of a game on one Mac. `LoopbackSession.simulateSpatial` stands in for the system coordinator.

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
| `SharedFrame.swift` | The shared frame: displacement, anchors, manual calibration and nudge, the fallback stage, the conversions. |
| `SharedAnchorTracker.swift` | Shared world anchors behind `SharePlayWorldAnchorHost`; the session's frame messages. |
| `ImmersiveSpaceCoordinator.swift` | The open/cycle/dismiss phase machine. |
| `CompositorContent+SharePlay.swift` | `.sharePlayFrame(session)` for a CompositorLayer (visionOS 26). |
| `Examples/SharedCube/` | The example app and the headset test protocol (its README): every participant's head as a cube, with the calibration and the nudges in the window (`xcodegen generate`, visionOS 26). |

## Compatibility

| Plugin | Untold Engine |
|---|---|
| 0.1.x (core only) | none required |

## License

MIT, see `LICENSE`.
