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
command line); `--cycle-space` also closes and reopens it 8 s later, the way
the join does.

The shared world anchors (`CubeAnchors.swift`) are an opt-in: they need the
engine's world-anchor API, still on its `feature/xr_shared_world_anchors`
branch. `project.yml` says how to point the example at a checkout of it and
set the `SHAREDCUBE_WORLD_ANCHORS` build flag. Without the flag the example
aligns by the system's participant pose, the mark and the sync, which is what
the nearby test passed with.

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
| 1. On both: build and run. Do not open the space yet. | The window's four numbered sections. |
| 2. On one: Start SharePlay; choose the other person from the nearby list. On the other: accept. | Both windows: `Joined with 1 other participant`, section 2 lists the other as `nearby`. Nothing opens by itself. |
| 3. On both: Open space. | A small cube on the floor at each device's own origin. Within a few seconds `our placement:` reads `from the system pose …` on both, each other's line reads `systemDisplacement`, and the other player's cube sits on their head with no manual step. (`spatial` may flicker to `no` as the space opens; the system pose comes back.) |
| 4. Player 1: stand on a spot, face a direction, tap Mark my spot, step aside. Player 2: stand on that spot, face the same way, tap Sync to the mark. | Player 2's line turns `manual · yaw …° · offset … m`; within a second player 1's says `synced by the other side`. The cubes now sit on the heads, on both devices. |
| 5. Move the sliders on either device. | The cube shifts live there; about a second after the sliders rest, the other device follows: it is one alignment seen from both sides. |
| 6. One leaves (Leave). | The other: `Waiting for others…`, the cube gone, the line back to `fallbackStage`. |
| 7. Join again from the call. | Back to step 2's state; the previous alignment is not reused (a new join is a new participant), so mark and sync again. |

Two automatic alignments come from the room map the system builds when both
players look at the same point, before any mark and sync:

- **The system's participant pose** (`system pose:` in the window): the
  coordinator's floor-level pose of this device in the shared frame, updated
  as the person moves; paired with the device pose on the floor it is the
  device's placement, announced to the others. This is what step 3 expects.
- **Shared world anchors** (the opt-in above): each device places an anchor
  at its origin, the others receive it in their own frame; a device that
  received one hands the alignment back as a sync. Expected when they cross:
  `anchors: own anchor … tracked` and the other's line `sharedAnchor` or
  `manual`. On the runs so far the anchors did not cross; the pose did.

If neither shows, note what the window says and go on to step 4.

**Result 2026-10-28:** step 3 passed on two headsets: both cubes on the
heads with no manual step, by the system's participant pose.

### B1. Remote, over FaceTime: the cube in our own render

Two headsets in two rooms. Compositor Services draws no Personas, so inside
the engine's space the other player is only their cube; this test is about
that cube.

| Step | Expected |
|---|---|
| 1. FaceTime call between the two headsets. On both: run. | As A.1. |
| 2. On one: Start SharePlay. On the other: accept. | Both windows: `Joined with 1 other participant`, `nearby 0`. Nothing opens by itself. |
| 3. On both: Open space. | The other player's cube in our space, moving as they move their head. Note the alignment on their line: `fallbackStage` puts them 2 m ahead, facing us; `systemDisplacement` means the coordinator delivered a seat for them in our space (`our placement:` says from what). Mark and Sync make no sense across rooms; the sliders still nudge. |
| 4. Walk, turn, crouch on one side. | The cube follows on the other side, at the right height and heading relative to its spot. |
| 5. Leave and rejoin as A.6 and A.7. | The same. |

### B2. Remote, over FaceTime: the cube on the spatial Persona

Needs the engine's RealityKit presenter (the hybrid of the Spatial Personas
plan), which puts the engine's frame in a space the system can seat Personas
in; it is not part of this gate. When it is in:

| Step | Expected |
|---|---|
| 1. As B1.1 and B1.2, Personas on. | `spatial yes` on both before the space opens. |
| 2. On both: Open space. Look at the other Persona. | The cube on the Persona's head, through `systemDisplacement`, where the system seated them (conversational template); `displacement` is not identity on at least one side. |

### C. Alone

| Step | Expected |
|---|---|
| 1. Start SharePlay with no call and nobody nearby. | `SharePlay is not available: start a FaceTime call, or share with people nearby.` The state stays idle. |
| 2. Open and close the space from the buttons twice. | Opens and closes both times; `space:` goes through opening, OPEN, closing, closed; the log shows the teardown each time. |

## What to report

The `[SharePlay]` log of both devices for each section, the participant
lines at steps A.3, A.4, B1.3 and B2.2, and how far the cube sat from the
head before and after the sync. Open an issue on this repository with them.
