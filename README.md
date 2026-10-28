# UntoldSharePlay

SharePlay for [Untold Engine](https://github.com/untoldengine/UntoldEngine) games on Apple Vision Pro, as one plugin: the group session (FaceTime call or nearby people), typed channels for game state and events, the participants and an optional host, the shared coordinate frame between headsets, and the immersive-space coordinator. A game keeps three things of its own: its `GroupActivity`, its wire types and what the messages do.

Status: stage 1 (the engine-free core) in progress. The design is the proposal `docs/proposals/SharePlayPlugin.md` in the engine repository.

## Products

| Product | Depends on | For |
|---|---|---|
| `UntoldSharePlay` | GroupActivities, SwiftUI | every game, including RealityKit ones (no engine dependency) |
| `UntoldSharePlayXR` (stage 2) | `UntoldEngineXR` | games rendering through the engine's XR runtime: shared world anchors and the immersive-space displacement |

## Build

```sh
swift build
swift test        # the core is tested on macOS through a loopback transport
```

## License

MIT, see `LICENSE`.
