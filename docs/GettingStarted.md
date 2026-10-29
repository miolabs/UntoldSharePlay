# SharePlay in an Untold Engine game

What the plugin gives a game: the group session (a FaceTime call, or people
nearby on visionOS 26), typed channels for the game's state and events, the
participants and an optional host, the shared coordinate frame between the
headsets, and the one place that opens and dismisses the immersive space.

What the game writes: three things. Its `GroupActivity`, its wire types, and
what the messages do. Everything else is the same in every game and lives
here.

This guide adds the pieces in the order a game needs them. The finished
version is [`Examples/SharedCube`](../Examples/SharedCube): every
participant's head as a cube, with the alignment controls in the window.
[`Recipes.md`](Recipes.md) has each piece on its own, and
[`Examples/HelloShare`](../Examples/HelloShare) is the same thing without the
engine or an immersive space: a window that shares a tap count.

**Requirements.** Xcode 26 or later. visionOS 26 on the headsets: nearby
sharing, the system's pose of each participant and the `CompositorContent`
API are visionOS 26 (the core compiles from visionOS 2). Two Vision Pros to
see anything: the simulator builds and runs the game, but has no SharePlay.

## 1. Add the package

Three ways.

**A new project, from the engine's CLI.** The `--shareplay` flag (engine
fork PR miolabs/UntoldEngine#86) adds the package, the entitlement, the
activity and a `SharePlayModel` with the session and the coordinator wired as
this guide does:

```bash
untoldengine create MyGame --platform visionos --shareplay
```

**An XcodeGen project.** In `project.yml`:

```yaml
packages:
  UntoldSharePlay:
    url: https://github.com/miolabs/UntoldSharePlay.git
    branch: develop
targets:
  MyGame:
    dependencies:
      - package: UntoldSharePlay
        product: UntoldSharePlay
    entitlements:
      path: Sources/MyGame/MyGame.entitlements
      properties:
        com.apple.developer.group-session: true
```

**Xcode.** File › Add Package Dependencies…, the URL above, branch
`develop`. Then the target's Signing & Capabilities › + Capability › Group
Activities, which is the `com.apple.developer.group-session` entitlement.

Nothing goes in `Info.plist`. The app's bundle identifier must belong to a
team that can sign for a device.

## 2. Declare the activity

The one type the system needs from the game. Its identifier is what the
system matches sessions on: every device must run a build with the same one,
so keep it stable.

```swift
import GroupActivities

struct MyGameActivity: GroupActivity {
    static let activityIdentifier = "com.example.mygame.arena"

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "My Game"
        metadata.subtitle = "Play together"
        metadata.type = .generic
        return metadata
    }
}
```

## 3. The session and its channels, once

Wire types are plain `Codable`. No sequence or timestamp fields: the plugin's
envelope carries them. A **state channel** is unreliable and the latest
message wins per sender (poses, scores: whatever the next frame supersedes).
An **event channel** is reliable and in order (hits, throws, snapshots:
whatever must arrive). A channel's id defaults to its message type's name.

The session is one main-actor object for the app. It is `@Observable`, so a
window shows it; the channels and the frame it hands out are lock-guarded,
so the render thread uses them. The render thread must never touch the
session itself: copy what the game needs into a lock-guarded object when the
session changes, as `GameShared` does below.

```swift
import SwiftUI
import UntoldSharePlay

/// Our head pose, in our own local frame; the receiver maps it (section 7).
struct HeadPose: Codable, Sendable {
    var matrix: SharePlayMatrix
}

/// Something that happened, which everyone must hear, in order.
enum GameEvent: Codable, Sendable {
    case hit(at: SIMD3<Float>)
}

/// What the render thread may read: copied here on the main actor, never
/// the session itself.
final class GameShared: @unchecked Sendable {
    private let lock = NSLock()
    private var othersStorage: [UUID] = []

    var others: [UUID] {
        get { lock.withLock { othersStorage } }
        set { lock.withLock { othersStorage = newValue } }
    }
}

@MainActor
@Observable
final class AppModel {
    let session: SharePlaySession
    let coordinator = ImmersiveSpaceCoordinator(id: "Arena")
    let poses: SharePlayStateChannel<HeadPose>
    let events: SharePlayEventChannel<GameEvent>
    let shared = GameShared()

    init() {
        session = SharePlaySession(MyGameActivity()) {
            $0.spatialTemplate = .conversational // .sideBySide (the default), .surround, .none
            $0.stateRate = 30 // the pump, in Hz; 45 by default
            $0.hostElection = .none // .lowestParticipantID for a host-authoritative game
        }
        poses = session.stateChannel(HeadPose.self) // unreliable, latest wins per sender
        events = session.eventChannel(GameEvent.self) // reliable, in order
        session.drive(coordinator) // the space follows the group (section 5)

        let shared = shared
        let session = session
        session.addEventHandler { _ in
            shared.others = session.others.map(\.id)
        }
    }
}
```

`groupImmersiveSpace` (on by default) asks the system for a shared immersive
space when the session joins: the players end up in one shared frame. A
window-only game turns it off.

## 4. The window

`SharePlayStatusView` is the status row: Start SharePlay, Leave, the state,
who is here. `startObserving()` runs once at launch: every session the system
hands the app is joined, whether this device started it or someone else did
from the FaceTime call. The coordinator is bound to SwiftUI's actions once
they exist.

```swift
struct ControlView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SharePlayStatusView(model.session)
            ForEach(model.session.others) { participant in
                Text("\(participant.id.uuidString.suffix(4)) · \(participant.isNearby ? "nearby" : "remote") · \(model.session.frame.summary(of: participant.id))")
                    .font(.caption)
            }
            HStack {
                Button("Open space") { model.coordinator.open(reason: "button") }
                    .disabled(model.coordinator.phase != .closed)
                Button("Close space") { model.coordinator.dismiss(reason: "button") }
                    .disabled(model.coordinator.phase != .open)
                Text("space: \(model.coordinator.phaseLabel)").font(.caption)
            }
        }
        .padding(28)
        .task {
            model.coordinator.bind(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
            model.session.startObserving()
        }
    }
}
```

Starting: `await session.start()` runs the system's share sheet and reports
`.started`, `.notAvailable` (no call, nobody nearby), `.cancelled` or
`.failed`. `.started` means only that the system accepted the activity; the
session arrives on its own, through `startObserving()`. The status view does
this for you.

The order that works on the headsets: **everyone joins first, then each
player opens the space.** A space opened before the join stays private, so
the plugin cycles an open space when the session joins (it closes and
reopens it). A closed space stays closed until the player opens it, unless
the session was driven with `opensOnRequest: true`.

## 5. The immersive space

visionOS allows one immersive-space request at a time, and an engine tears
down asynchronously after the space closes, so every open and dismiss goes
through `ImmersiveSpaceCoordinator`: at most one in flight, an open during a
teardown deferred until the teardown is reported, one retry after an error, a
space presented without a renderer recovered by a dismiss.

The layer closure reports the start; the render thread reports the teardown
after `runLoop()` returns; `.sharePlayFrame(session)` feeds the system's
displacement of the space into the frame, should the system ever move it.

```swift
import CompositorServices
import UntoldEngine
import UntoldEngineXR

@main
struct MyGameApp: App {
    @State private var model = AppModel()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup {
            ControlView(model: model)
        }
        ImmersiveSpace(id: "Arena") {
            ArenaSpace(model: model)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}

struct ArenaSpace: CompositorContent {
    let model: AppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: ArenaLayerConfiguration()) { layerRenderer in
            guard Holder.shared.xr == nil else {
                // A layer before the last teardown finished: the coordinator cycles the empty space.
                model.coordinator.spaceDidStart(rendering: false)
                return
            }
            guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
            Holder.shared.xr = xr
            model.coordinator.spaceDidStart(rendering: true)
            xr.setImmersionMode(xrImmersionMode: .mixed)

            let game = Game(frame: model.session.frame, poses: model.poses, events: model.events, shared: model.shared)
            Holder.shared.game = game
            game.start()
            xr.setupCallbacks(gameUpdate: { deltaTime in game.update(deltaTime: deltaTime) }, handleInput: {})

            let coordinator = model.coordinator
            let thread = Thread {
                xr.start()
                xr.runLoop()
                // The space closed. Release the engine now and report the teardown.
                game.shutdown()
                Task { @MainActor in
                    Holder.shared.release()
                    coordinator.spaceDidTearDown()
                }
            }
            thread.name = "XR Render Thread"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        .sharePlayFrame(model.session)
    }
}

/// The engine's usual layer: a dedicated layout, sRGB colour, no foveation.
struct ArenaLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities _: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}

/// Retains the XR system and the game while the space is open; releases
/// them when it closes.
final class Holder: @unchecked Sendable {
    static let shared = Holder()
    var xr: UntoldEngineXR?
    var game: Game?

    @MainActor
    func release() {
        if let xr {
            setRendering(.extensions(.removeAll))
            xr.clearSpatialInput()
            xr.stop()
        }
        destroyAllEntities()
        xr = nil
        game = nil
    }
}
```

**Release the engine synchronously after `runLoop()` returns**, as above:
stop it, clear the spatial input, `destroyAllEntities()` with no completion,
drop the holder's references, then `spaceDidTearDown()`. Do not wait for
`shutdownUntoldEngineXR`'s completion there: it fires from a frame's finalize
pass, and no frame runs once the loop has returned, so a game with entities
would never report the teardown and the space could never reopen. The
headsets found this one.

## 6. Every frame, on the render thread

The game publishes its head pose as the engine reports it, in its own local
frame, and feeds the same pose to the frame, which pairs it with the system's
pose of this device (section 7). What the others published is read with
`latestAll()`, mapped into this device's frame with `toLocal`, and placed.
Events are drained once per frame.

```swift
final class Game {
    private let frame: SharedFrame
    private let poses: SharePlayStateChannel<HeadPose>
    private let events: SharePlayEventChannel<GameEvent>
    private let shared: GameShared
    private var avatars: [UUID: EntityID] = [:]

    init(frame: SharedFrame, poses: SharePlayStateChannel<HeadPose>, events: SharePlayEventChannel<GameEvent>, shared: GameShared) {
        self.frame = frame
        self.poses = poses
        self.events = events
        self.shared = shared
    }

    func start() {
        setSceneReady(true)
    }

    func shutdown() {
        for avatar in avatars.values { destroyEntity(entityId: avatar) }
        avatars.removeAll()
    }

    func update(deltaTime _: Float) {
        guard let xr = Holder.shared.xr, let head = xr.currentDevicePose else { return }
        frame.updateDevicePose(head) // pairs with the system's pose of this device
        poses.publish(HeadPose(matrix: SharePlayMatrix(head))) // our local frame, as it is

        let present = Set(shared.others)
        for (participant, received) in poses.latestAll() where present.contains(participant) {
            let local = frame.toLocal(received.message.matrix.matrix, from: participant)
            place(avatar(for: participant), at: local)
        }
        for (participant, avatar) in avatars where !present.contains(participant) {
            destroyEntity(entityId: avatar)
            avatars[participant] = nil
        }
        for event in events.drain() {
            if case let .hit(point) = event.message {
                spark(at: frame.toLocal(point: point, from: event.sender))
            }
        }
    }

    private func avatar(for participant: UUID) -> EntityID {
        if let existing = avatars[participant] { return existing }
        let entity = createEntity()
        setEntityMeshDirect(entityId: entity, meshes: BasicPrimitives.createCube(extent: 0.2), assetName: "Head-\(participant.uuidString.prefix(8))")
        avatars[participant] = entity
        return entity
    }

    private func place(_ entity: EntityID, at pose: simd_float4x4) {
        translateTo(entityId: entity, position: SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z))
        var rotation = pose
        rotation.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        rotateTo(entityId: entity, rotation: rotation)
    }

    private func spark(at _: SIMD3<Float>) {}
}
```

A pose that is older than a few hundred milliseconds (`received.age`) is a
participant whose frames stopped: hide the avatar rather than freeze it.

## 7. Where the others are

Every device publishes poses in its own local frame, as they are. Each
device also announces its *placement* in the group's shared frame when it
knows one, and the receiver maps a participant's poses into its own frame by
the first of these it has:

1. **Manual**: an alignment the players solved by hand (below).
2. **Shared anchor**: the participant's shared world anchor (nearby; needs
   the engine's world-anchor API, still on its branch).
3. **System placements**: ours composed with theirs. The system coordinator
   gives each device its pose in the shared frame once the players are in a
   shared context: nearby, that pose tracks the device as the person moves,
   from the room map the system builds when both players look at the same
   point (the share sheet asks them to); over FaceTime it is the seat the
   spatial template gave the device. The frame pairs it with the device pose
   on the floor, and that is the placement.
4. **Fallback stage**: a row 2 m ahead, facing this device, 0.8 m apart, in
   join order.

Nothing to write for 3 and 4: `updateDevicePose` every frame and
`.sharePlayFrame` on the layer are the inputs. On two headsets nearby, each
player's cube sits on the other's head within seconds of opening the space,
with no manual step; over FaceTime it sits at the other's seat. The window
shows which alignment is in force (`frame.alignment(of:)`,
`frame.summary(of:)`) and where this device thinks it is
(`frame.displacementSummary`).

**By hand**, when the system's alignment is off or absent: one player marks
a spot and steps aside; the other stands on it, faces the same way and
syncs. The solved alignment is installed on one side and its inverse sent to
the other, so it is one alignment seen from both sides; the sliders nudge it
for both.

```swift
// Player 1, on the render thread (the head pose is theirs):
frame.publishMark(localPose: head)

// Player 2, standing on the mark, facing the same way:
let point = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
let heading = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
switch frame.calibrate(with: participant, localPoint: point, localHeading: heading) {
case let .solved(yawDegrees, offset): print("aligned: yaw \(yawDegrees)°, offset \(offset) m")
case let .failed(reason): print("not aligned: \(reason)") // "no mark from the other side yet", "hold the headings level"
}

// Either player, from the window: a fine tune, re-sent to the other side once the sliders rest 0.3 s.
frame.setNudge(SIMD2<Float>(side, forward), for: participant)
```

The window's buttons talk to the render thread through a lock-guarded
request (`Examples/SharedCube/Sources/SharedCube/CubeControls.swift`), since
the head pose lives there.

## 8. Try it

**On the Mac**, without SharePlay: the loopback transport runs two sessions
in one process and routes their frames with optional loss, reordering and
delay. The plugin's tests do this; [`Recipes.md`](Recipes.md) shows the four
lines it takes.

**In the simulator**: the game builds and opens its space, but there is no
SharePlay. `Examples/SharedCube` takes `--open-space` and `--cycle-space` as
launch arguments to exercise the space without a session.

**On two headsets**: the protocol in
[`Examples/SharedCube/README.md`](../Examples/SharedCube/README.md) (nearby
in one room, over FaceTime, alone), with what to expect at each step. Every
step prints a `[SharePlay]` line; from a Mac,

```bash
log stream --predicate 'eventMessage CONTAINS "[SharePlay]"'
```

collects them from a connected headset, and the two devices' logs are what
to compare when something is off.

## 9. Without the engine

The core has no engine dependency: a RealityKit game uses the session, the
channels and the coordinator as above, with three differences. Its
`ImmersiveSpace` holds a `RealityView`, so the coordinator is made with
`tracksTeardown: false` and `spaceDidTearDown()` is called from the view's
`onDisappear`. Its scene is the frame the system seats everyone in, so the
app says so once with `session.frame.setSystemDisplacement(matrix_identity_float4x4)`
and publishes poses in the scene's frame. There is no `CompositorLayer`, so
no `.sharePlayFrame`. No game has exercised this path yet; Oche's SharePlay
milestone (stage 4 in the README) is the first.

## 10. Reading on

- The [README](../README.md): the reference. The API in one listing, the
  shared frame's precedence in full, the immersive space, threads, and the
  lessons the plugin encodes from the three games that wrote SharePlay by
  hand.
- [`Recipes.md`](Recipes.md): one task at a time.
- [`Examples/SharedCube`](../Examples/SharedCube): the engine example and the
  headset protocol.
- [`Examples/HelloShare`](../Examples/HelloShare): the window-only example.
