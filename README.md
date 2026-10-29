# UntoldSharePlay

SharePlay for [Untold Engine](https://github.com/untoldengine/UntoldEngine) games on Apple Vision Pro, as one plugin: the group session (a FaceTime call, or people nearby on visionOS 26), typed channels for game state and events, the participants and an optional host, the shared coordinate frame between headsets, and the immersive-space coordinator. A game keeps three things of its own: its `GroupActivity`, its wire types, and what the messages do.

It comes from three hand-written copies of the same code: CoolSaber's duel in [UntoldArcade](https://github.com/untoldengine/UntoldArcade), the RealityKit presenter spike, and the plan of the Oche darts game. The design note is `docs/proposals/SharePlayPlugin.md` in the engine repository.

## Status

| Stage | What | State |
|---|---|---|
| 1 | The core: session, channels, participants and host election, status view, diagnostics, the transport seam with the GroupActivities and loopback transports; tests on macOS | **built** (PR #1) |
| 2 | The shared frame (the system's displacement, shared world anchors, the manual calibration, the fallback stage), the immersive-space coordinator, the displacement modifier for a CompositorLayer, the `SharedCube` example | **built** (this branch); the engine side of the shared anchors waits for the engine's world-anchor API |
| 2b | The headset test of stages 1 and 2 with `Examples/SharedCube`: the protocol is in the example's README | nearby **passed 2026-10-28** (both cubes on the heads, no manual step); FaceTime with the cube only **passed 2026-10-29**; alone **next**; FaceTime with the Persona waits for the engine's RealityKit presenter |
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

## Documentation

| Read | For |
|---|---|
| [docs/GettingStarted.md](docs/GettingStarted.md) | SharePlay in an Untold Engine game, step by step: the package, the activity, the session and its channels, the window, the immersive space, the render thread, the alignment, how to try it. |
| [docs/Recipes.md](docs/Recipes.md) | One task at a time, each with complete code: share a value, tell everyone, seed a newcomer, pick a host, show the others, open the space together, line up by hand, try it on a Mac, read the diagnostics. The Mac ones are tests. |
| [Examples/HelloShare](Examples/HelloShare/README.md) | The smallest game: a window that shares a tap count and a wave. No engine, no immersive space. |
| [Examples/SharedCube](Examples/SharedCube/README.md) | The engine game: every participant's head as a cube in the immersive space, the alignment controls, and the headset test protocol. |
| The sections below | The reference: the API in one listing, the shared frame's precedence, the immersive space, threads, the lessons the plugin encodes, the layout. |

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

Every device publishes poses in its own local frame, as they are: ARKit's
world frame on the engine path, the scene's frame on a RealityView space.
Each device also announces its *placement* in the group's shared frame when
it knows one, and the receiver maps a participant's poses into its own frame
by one of four alignments, in this order of precedence:

1. **Manual**: the calibration the players solved (a mark, or one point both
   can touch), wins over everything.
2. **Shared anchor**: the participant's shared world anchor, placed at their
   origin (nearby, visionOS 26, through the engine's world-anchor API).
3. **System placements**: ours composed with theirs. A placement comes from
   SwiftUI's `immersiveSpaceDisplacement` when the system moved our space, or
   from the system coordinator's pose of this device in the shared frame: a
   floor-level position and heading, which nearby tracks the device as the
   person moves and over FaceTime is the seat the spatial template gave us,
   reset when the group's space opens. Each pose is paired once with the
   device pose on the floor (a head's height, or a later step, never enters
   it), and a pairing made while the head moves does not replace one made
   still. A Compositor Services space the system leaves where it is
   (identity), so the pose is what aligns the devices; the headsets confirmed
   it is delivered there, nearby and over FaceTime.
4. **Fallback stage**: a row 2 m ahead, facing us, 0.8 m apart, in join order.

```swift
// Every frame, on the render thread: the device pose pairs with the system's pose of us.
session.frame.updateDevicePose(head)
poses.publish(Poses(head: head))                               // our local frame, as it is
// After receiving: the participant's pose in our local frame, by the alignment in force.
let local = session.frame.toLocal(received.message.head, from: participant)
session.frame.alignment(of: participant)      // .manual, .sharedAnchor, .systemDisplacement, .fallbackStage
session.frame.summary(of: participant)        // for a diagnostics row
session.frame.fallbackStage = .init(distance: 2, spacing: 0.8)

// A CompositorLayer app feeds the system's displacement (visionOS 26):
CompositorLayer(configuration: config) { layerRenderer in ... }
    .sharePlayFrame(session)
// A RealityView app's scene is the shared frame: say so once.
session.frame.setSystemDisplacement(matrix_identity_float4x4)

// The manual calibration, with marks: one player marks their spot (a pose in
// their local frame, the head or a controller) and steps aside; the other
// stands on it, faces the same way and calibrates to the mark.
session.frame.publishMark(localPose: head)                       // player 1, sent to everyone
switch session.frame.calibrate(with: participant, localPoint: p, localHeading: h) {   // player 2, on the mark
case let .solved(yawDegrees, offset): ...   // installed here, the inverse sent to the other side
case let .failed(reason): ...               // "no mark from the other side yet", "hold the headings level"
}
// Or with one physical point both can touch at once (CoolSaber's controllers), raw from their state:
session.frame.calibrate(with: participant, localPoint: p, localHeading: h, remotePoint: rp, remoteHeading: rh)
session.frame.setNudge(SIMD2(side, forward), for: participant)   // fine tune; one alignment for both sides, re-sent once it rests 0.3 s
```

Shared world anchors (visionOS 26, nearby participants): the session places this device's anchor at its origin as soon as someone nearby is in the session, announces its id on its own channel, and maps every other participant's anchor into the frame; a device that received the other's anchor hands the alignment back as a sync, so one working direction aligns both. This needs a world-tracking host: `session.anchors.attach(host)` with a `SharePlayWorldAnchorHost` (four methods: add a shared anchor, remove it, observe updates, stop observing). The engine's XR runtime conforms once its world-anchor API ships; until then a game on CoolSaber's engine branch writes the 20-line conformance itself (`Examples/SharedCube/Sources/SharedCube/CubeAnchors.swift`).

### The immersive space

`ImmersiveSpaceCoordinator` is the one place that opens and dismisses the space (visionOS allows one request at a time): at most one in flight, an open during the engine's teardown deferred until `spaceDidTearDown()`, one retry after an error, a space presented without a renderer recovered by a dismiss, and `joinGroup`, which cycles an open space because a space opened before the session joined stays private.

```swift
let space = ImmersiveSpaceCoordinator(id: "Arena")          // tracksTeardown: false for a RealityView space
space.bind(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
session.drive(space)      // join first, then the player opens the space: an open space is cycled on the
                          // join (it would stay private), the space is dismissed when the group leaves
                          // its space; drive(space, opensOnRequest: true) also opens it on the group's request
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

The core (62 tests) is tested on macOS through `LoopbackTransport`: a `LoopbackHub` makes one transport per simulated participant, a session for all of them on the first `start()`, and routes frames between the joined ones with optional loss, reordering and delay on the unreliable path. The same hub runs two instances of a game on one Mac. `LoopbackSession.simulateSpatial` stands in for the system coordinator.

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
| `Examples/HelloShare/` | The smallest example: a window sharing a tap count and a wave, no engine (`xcodegen generate`, visionOS 26). |
| `docs/` | The integration guide and the recipes. |

## Compatibility

| Plugin | Untold Engine |
|---|---|
| 0.1.x (core only) | none required |

## License

MIT, see `LICENSE`.
