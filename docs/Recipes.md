# Recipes

One task at a time, each with complete code. The ones that run without a
headset are also tests, in
[`Tests/UntoldSharePlayTests/RecipesTests.swift`](../Tests/UntoldSharePlayTests/RecipesTests.swift),
where the two devices are two sessions in one process over the loopback
transport; the others are taken from
[`Examples/SharedCube`](../Examples/SharedCube), which builds for the
headset. [`GettingStarted.md`](GettingStarted.md) puts the pieces together
in order.

Every recipe assumes a session made once on the main actor and observing:

```swift
let session = SharePlaySession(MyGameActivity())
session.startObserving()
```

## 1. Share a value everyone reads

A **state channel**: unreliable, the latest message wins per sender, and a
value published before the pump ran replaces the unsent one. For what the
next frame supersedes: poses, a score, a timer.

```swift
struct Score: Codable, Sendable { var points: Int }
let scores = session.stateChannel(Score.self)

// Whenever it changes (any thread):
scores.publish(Score(points: 4))

// Whenever you draw (any thread):
for (participant, received) in scores.latestAll() where received.age < 1 {
    print("\(participant): \(received.message.points) points, \(received.age) s ago")
}
scores.latest(from: participant)?.message.points
```

A sender never receives its own value. `received.age` is the seconds since
the frame arrived: a participant whose frames stopped goes stale, and the
game hides what it drew for them.

Proof: `testShareAValueEveryoneReads`.

## 2. Tell everyone something happened

An **event channel**: reliable, in order, to everyone or to one participant.
For what must arrive: a hit, a throw, a lobby command. `drain()` once per
frame from the thread that handles the events.

```swift
enum Shout: Codable, Sendable { case wave, snapshot(points: Int) }
let shouts = session.eventChannel(Shout.self)

shouts.send(.wave)                                       // to everyone
shouts.send(.snapshot(points: 9), to: .only([participant])) // to one

// Once per frame:
for shout in shouts.drain() {
    switch shout.message {
    case .wave: print("\(shout.sender) waved")
    case let .snapshot(points): print("\(shout.sender) says \(points)")
    }
}
```

An event sent before the session joined is queued and goes out at the join,
to whoever is in the session by then; one sent to a participant who is not
there is dropped. A newcomer gets nothing that was sent before they joined,
which is what recipe 3 is for.

Proof: `testTellEveryoneSomethingHappened`.

## 3. Give a newcomer the current state

The session's events (main actor): `.participantJoined` is the moment to
send the newcomer a snapshot, on an event channel, to them alone.

```swift
session.addEventHandler { event in
    if case let .participantJoined(id) = event {
        shouts.send(.snapshot(points: currentPoints), to: .only([id]))
    }
}
```

The other events: `.joined(local:)`, `.participantLeft`, `.hostChanged`,
`.spatialChanged`, `.systemPoseChanged`, `.groupImmersionChanged`, `.left`,
`.invalidated`.

Proof: `testGiveTheNewcomerTheCurrentState`.

## 4. Pick one device to decide

A host-authoritative game sets a **host election** policy when it makes the
session; every device then gives the same answer, and the host moves when
the host leaves.

```swift
let session = SharePlaySession(MyGameActivity()) {
    $0.hostElection = .lowestParticipantID
}

session.isHost      // on exactly one device
session.hostID      // the same on every device
session.addEventHandler { event in
    if case .hostChanged = event, session.isHost {
        shouts.send(.snapshot(points: currentPoints)) // the new host re-broadcasts its state
    }
}
```

The host validates the events it receives and broadcasts the state; the
other devices apply what the host sends. Seats, turns and spectators stay in
the game.

Proof: `testPickOneDeviceToDecide`.

## 5. Show the others where they are

On the engine's render thread, every frame: feed the device pose to the
frame, publish it as it is, map what the others published into this
device's frame, and place something there. The mapping is the alignment in
force for that participant (manual, shared anchor, the system's placements,
or the fallback stage): the game never computes it.

```swift
struct HeadPose: Codable, Sendable { var matrix: SharePlayMatrix }
let poses = session.stateChannel(HeadPose.self) // once, main actor
let frame = session.frame

// Every frame, render thread:
if let head = xr.currentDevicePose {
    frame.updateDevicePose(head)
    poses.publish(HeadPose(matrix: SharePlayMatrix(head)))
}
for (participant, received) in poses.latestAll() where others.contains(participant) {
    let local = frame.toLocal(received.message.matrix.matrix, from: participant)
    translateTo(entityId: cube(for: participant), position: SIMD3<Float>(local.columns.3.x, local.columns.3.y, local.columns.3.z))
}
```

`others` is the participant list copied out of the session on the main
actor into a lock-guarded object: the render thread never reads the session.
`frame.alignment(of:)` says which alignment placed them; `frame.summary(of:)`
is a line for the window.

Proof: `Examples/SharedCube/Sources/SharedCube/CubeGame.swift`.

## 6. Open the space together

All opens and dismisses go through the coordinator; the session drives it.
Everyone joins first, then each player opens the space: the plugin cycles a
space that was open before the join, because such a space stays private.

```swift
let coordinator = ImmersiveSpaceCoordinator(id: "Arena")
session.drive(coordinator)

// In the window, once SwiftUI's actions exist:
coordinator.bind(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
Button("Open space") { coordinator.open(reason: "button") }.disabled(coordinator.phase != .closed)

// In the CompositorLayer closure:
coordinator.spaceDidStart(rendering: true)

// After xr.runLoop() returns, on the main actor, once the engine is released:
coordinator.spaceDidTearDown()
```

`drive(coordinator, opensOnRequest: true)` also opens a closed space when
the system asks for the group immersive space. A `RealityView` space uses
`ImmersiveSpaceCoordinator(id:tracksTeardown: false)` and calls
`spaceDidTearDown()` from `onDisappear`.

Proof: `Examples/SharedCube/Sources/SharedCube/SharedCubeApp.swift`;
`ImmersiveSpaceCoordinatorTests`.

## 7. Line up by hand

When the system's alignment is off or absent. One player marks a spot and
steps aside; the other stands on it, faces the same way and syncs. One
alignment, seen from both sides; the sliders nudge it for both.

```swift
// Player 1 (render thread, the head pose is theirs):
frame.publishMark(localPose: head)

// Player 2, on the mark, facing the same way:
let point = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
let heading = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
let outcome = frame.calibrate(with: participant, localPoint: point, localHeading: heading)
// .solved(yawDegrees:offset:) here; the inverse goes to player 1 by itself.

// Either side, from the window:
frame.setNudge(SIMD2<Float>(side, forward), for: participant)
```

The window knows a mark arrived through `frame.mark(from: participant)`,
and a manual alignment is in force when `frame.alignment(of: participant)`
is `.manual`.

Proof: `SessionFrameTests.testMarkThenSyncAcrossSessions`,
`testCalibrationReachesTheOtherSideAndNudgesFollow`.

## 8. Try it on a Mac

The **loopback transport** stands in for GroupActivities: a hub makes one
transport per simulated participant, a session for all of them on the first
`start()`, and routes frames between the joined ones, with optional loss,
reordering and delay on the unreliable path.

```swift
let hub = LoopbackHub()
let a = SharePlaySession(transport: hub.makeTransport(id: UUID()))
let b = SharePlaySession(transport: hub.makeTransport(id: UUID(), nearby: true))
a.startObserving()
b.startObserving()
await a.start() // both join
```

The same hub runs two instances of a game in one process on a Mac, which is
how the game's logic is tried without a headset. `LoopbackHub.Options`
(`unreliableLoss`, `reorderUnreliable`, `delay`, `seed`) makes the link bad
on purpose; `hub.session(for:)?.simulateSpatial(_:)` stands in for the
system coordinator's spatial reports.

Proof: `testTryItOnAMacWithALossyLink`; every test in
`Tests/UntoldSharePlayTests`.

## 9. Read the diagnostics and the log

```swift
session.diagnostics.summary()   // one line: frames and bytes per channel, stale drops, failures
session.diagnostics.snapshot()  // the counters, per channel
session.statusMessage           // what the status view says
SharePlayLog.isEnabled = false  // the [SharePlay] lines, on by default
```

Every step the plugin takes prints a `[SharePlay]` line: the session, the
participants, the space's phases, the spatial reports and the placements.
From a Mac, `log stream --predicate 'eventMessage CONTAINS "[SharePlay]"'`
collects them from a connected headset; the two devices' logs side by side
are what to read when something is off.
