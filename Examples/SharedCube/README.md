# SharedCube

The plugin's example and its headset test. Every participant's head is a cube
in everyone's room, rendered by the engine through a `CompositorLayer`; the
window shows the session, the space's phase, each participant's alignment,
the calibration and its fine-tune sliders.

## Build

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # put your team in DEVELOPMENT_TEAM
xcodegen generate
open SharedCube.xcodeproj
```

visionOS 26 (the `CompositorContent` API). The engine comes from the fork's
`develop`; the plugin from this repository by path. Run on a Vision Pro: the
simulator builds and opens the space, but has no SharePlay. The launch
argument `--open-space` opens the space at launch (simulator runs from the
command line).

## What the window shows

- The session's status row: Start SharePlay / Leave, the state, the
  participants, `spatial yes/no`, `nearby n`, the traffic per channel.
- `space: closed / opening… / OPEN / closing…`: the coordinator's phase.
- `head (x, y, z) m · n cube(s)`: our head pose, how many remote heads are placed.
- One line per other participant: its alignment (`fallbackStage`,
  `systemDisplacement`, `sharedAnchor`, `manual`) and a summary.
- `anchors: …` and `displacement …`: the shared-anchor state and the system's
  displacement of the space.
- `Sync`: the manual calibration (both players stand on one spot, facing the
  same way, then one taps). The sliders appear once a manual solution exists.

Every step also prints a `[SharePlay]` line; `log stream --predicate
'eventMessage CONTAINS "[SharePlay]"'` from a Mac, or Console, collects them.

## The headset test

Two Vision Pros, both on visionOS 26, both signed in to accounts that can
FaceTime each other. Note what you see at each step; the expected result is
in the second column.

### A. Nearby, same room (visionOS 26 nearby SharePlay)

| Step | Expected |
|---|---|
| 1. On both: build, run, Open space. | A small cube on the floor at each device's own origin. |
| 2. On one: Start SharePlay; choose the other person from the nearby list. On the other: accept. | Both windows: `Joined with 1 other participant`, `nearby 1`; the space closes and reopens on each (the join cycles it so it becomes the group's). |
| 3. Look at each other. | A cube at the other person's head, within a few centimetres, if the system aligned the spaces: the participant line says `systemDisplacement`; `displacement` is not identity. If it says `systemDisplacement` but the cube is somewhere else, the displacement is identity for nearby participants in a Metal space (what CoolSaber saw): go to step 4. |
| 4. Stand on one spot, face the same way, tap Sync on one device. | Its line turns `manual · yaw …° · offset … m`; within a second the other device's line says `synced by the other side`. The cubes now sit on the heads. |
| 5. Move the sliders on the device that synced. | The cube shifts live; about a second after the sliders rest, the other device follows. |
| 6. One leaves (Leave). | The other: `Waiting for others…`, the cube gone, the line back to `fallbackStage`. |
| 7. Join again from the call. | Back to step 2's state; the previous calibration is not reused (a new join is a new participant). |

Shared world anchors are not part of this test yet: the engine's world-anchor
API is still on CoolSaber's engine branch, so `anchors:` shows `no anchor
host`. When it lands, step 3 is expected to show `sharedAnchor` without the
manual sync.

### B. Remote, over FaceTime (spatial Personas)

| Step | Expected |
|---|---|
| 1. FaceTime call between the two headsets, Personas on. On both: run, Open space. | As A.1. |
| 2. On one: Start SharePlay. On the other: accept. | Both: `spatial yes`, `nearby 0`; the space cycles on each. |
| 3. Look where the system seats the other Persona (conversational template). | A cube at the Persona's head, through `systemDisplacement`; `displacement` is not identity on at least one side. |
| 4. Leave and rejoin as A.6 and A.7. | The same. |

No Persona is visible inside the engine's space (Compositor Services draws no
Personas); the cube is the stand-in. That limit is the RealityKit presenter
plan's business, not this test's.

### C. Alone

| Step | Expected |
|---|---|
| 1. Start SharePlay with no call and nobody nearby. | `SharePlay is not available: start a FaceTime call, or share with people nearby.` The state stays idle. |
| 2. Open and close the space from the buttons twice. | Opens and closes both times; `space:` goes through opening, OPEN, closing, closed; the log shows the teardown each time. |

## What to report

The `[SharePlay]` log of both devices for each section, the participant
lines at steps A.3, A.4 and B.3, and how far the cube sat from the head
before and after the sync. Open an issue on this repository with them.
