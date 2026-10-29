# HelloShare

The plugin's smallest game, in one file: a window that shares a tap count
and a wave over SharePlay. No immersive space, no engine. It shows the three
things a game writes (its activity, its wire types, what the messages do)
and the two kinds of channel, and nothing else.

## Build

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # put your team in DEVELOPMENT_TEAM
xcodegen generate
open HelloShare.xcodeproj
```

The plugin comes from this repository by path. Run on two Vision Pros: the
simulator builds and shows the window, but has no SharePlay.

## Try

1. On both: run. Start SharePlay from the window: the system's sheet offers
   the FaceTime call, or the people nearby. The other accepts.
2. Both windows read `Joined with 1 other participant`.
3. Tap on one: the other's window shows the count a moment later, and it
   only ever goes up (the latest count wins; a lost frame is replaced by the
   next).
4. Wave on one: `xxxx waved` appears on the other, once per wave, in order.
5. Leave on one: the other's count line goes away.

Every step prints a `[SharePlay]` line; `log stream --predicate
'eventMessage CONTAINS "[SharePlay]"'` from a Mac collects them.
