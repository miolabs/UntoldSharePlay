//
//  SharedCubeApp.swift
//  SharedCube
//
//  The plugin's example: a control window with the session's status, the
//  space's phase and the calibration, and an immersive space in which every
//  other participant's head is a cube. Start SharePlay from a FaceTime call
//  or with people nearby; the session opens the shared space.
//

import CompositorServices
import SwiftUI
import UntoldEngine
import UntoldEngineXR
import UntoldSharePlay

@MainActor
@Observable
final class AppModel {
    let session: SharePlaySession
    let coordinator = ImmersiveSpaceCoordinator(id: "SharedCube")
    let controls = CubeControls()
    let poses: SharePlayStateChannel<HeadPose>

    init() {
        session = SharePlaySession(SharedCubeActivity()) {
            $0.spatialTemplate = .conversational
            $0.stateRate = 30
        }
        poses = session.stateChannel(HeadPose.self)
        session.drive(coordinator)
        // The render thread must never touch the session (a main-actor object):
        // the game reads the participant list from the controls, copied here.
        let controls = controls
        let session = session
        session.addEventHandler { _ in
            controls.others = session.others.map(\.id)
        }
    }
}

@main
struct SharedCubeApp: App {
    @State private var model = AppModel()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup {
            ControlView(model: model)
        }
        .windowStyle(.plain)
        .defaultSize(width: 640, height: 720)

        ImmersiveSpace(id: "SharedCube") {
            CubeSpace(model: model)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}

struct ControlView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var nudge = SIMD2<Float>(0, 0)
    let model: AppModel

    var body: some View {
        // Once a second, so the frame's and the anchors' summaries (plain
        // lock-guarded values, not observable) read fresh.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content
        }
        .task {
            model.coordinator.bind(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
            model.session.startObserving()
            // `--open-space` opens the immersive space at launch (simulator runs);
            // `--cycle-space` also cycles it 8 s later, as the join does.
            if CommandLine.arguments.contains("--open-space") || CommandLine.arguments.contains("--cycle-space") {
                model.coordinator.open(reason: "launch argument")
            }
            if CommandLine.arguments.contains("--cycle-space") {
                try? await Task.sleep(for: .seconds(8))
                model.coordinator.joinGroup(reason: "launch argument")
            }
        }
    }

    private var content: some View {
        let session = model.session
        let frame = session.frame
        let markedBy = session.others.first { frame.mark(from: $0.id) != nil }
        let spaceOpen = model.coordinator.phase == .open
        return VStack(alignment: .leading, spacing: 14) {
            Text("Shared Cube").font(.largeTitle).bold()

            Text("1 · Share").font(.headline)
            Text("Start SharePlay opens the system's sheet: a FaceTime call, or people nearby. Everyone joins first; then open the space.")
                .font(.caption).foregroundStyle(.secondary)
            SharePlayStatusView(session)

            Text("2 · Who is here").font(.headline)
            if session.others.isEmpty {
                Text("Nobody else yet.").font(.caption)
            }
            ForEach(session.others) { participant in
                Text("\(participant.id.uuidString.suffix(4)) · \(participant.isNearby ? "nearby" : "remote") · \(String(describing: frame.alignment(of: participant.id))) · \(frame.summary(of: participant.id))")
                    .font(.caption)
            }

            Text("3 · Space").font(.headline)
            HStack {
                Button("Open space") { model.coordinator.open(reason: "button") }
                    .disabled(model.coordinator.phase != .closed)
                Button("Close space") { model.coordinator.dismiss(reason: "button") }
                    .disabled(!spaceOpen)
                Text("space: \(model.coordinator.phaseLabel)").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.controls.headSummary + " · \(model.controls.cubeCount) cube(s)").font(.caption)

            Text("4 · Align, nearby").font(.headline)
            Text("One player: stand on a spot, face a direction, tap Mark, step aside. The other: stand on that spot, face the same way, tap Sync. It is one alignment seen from both sides: the sliders move it for both players.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Mark my spot") { model.controls.requestMark() }
                    .disabled(session.others.isEmpty || !spaceOpen)
                Button(markedBy.map { "Sync to \($0.id.uuidString.suffix(4))'s mark" } ?? "Sync (no mark yet)") { model.controls.requestCalibration() }
                    .disabled(markedBy == nil || !spaceOpen)
            }
            Text(model.controls.lastCalibration).font(.caption)
            if let other = session.others.first, frame.alignment(of: other.id) == .manual {
                VStack {
                    Slider(value: Binding(get: { Double(nudge.x) }, set: { nudge.x = Float($0); frame.setNudge(nudge, for: other.id) }), in: -0.5 ... 0.5) { Text("side") }
                    Slider(value: Binding(get: { Double(nudge.y) }, set: { nudge.y = Float($0); frame.setNudge(nudge, for: other.id) }), in: -0.5 ... 0.5) { Text("forward") }
                }
            }
            Text("anchors: \(session.anchors.summary) · our placement: \(frame.displacementSummary)").font(.caption)
            Text("system pose: \(session.systemPose.map { String(format: "(%.2f, %.2f, %.2f) m", $0.columns.3.x, $0.columns.3.y, $0.columns.3.z) } ?? "none")").font(.caption)
            Spacer()
        }
        .padding(28)
    }
}

/// The immersive space's content: the engine's layer, with the session's
/// displacement feed. The game runs on its own thread; its end reports the
/// teardown to the coordinator so a reopen waits for it.
struct CubeSpace: CompositorContent {
    let model: AppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: CubeLayerConfiguration()) { layerRenderer in
            guard CubeHolder.shared.xr == nil else {
                print("SharedCube: layer created before teardown finished — empty space")
                model.coordinator.spaceDidStart(rendering: false)
                return
            }
            guard let xr = UntoldEngineXR(layerRenderer: layerRenderer) else { return }
            CubeHolder.shared.xr = xr
            model.coordinator.spaceDidStart(rendering: true)
            // Shared world anchors through the engine, when the build has the
            // API (CubeAnchors.swift); off, the frame aligns by the system pose.
            #if SHAREDCUBE_WORLD_ANCHORS
            model.session.anchors.attach(xr)
            #endif
            xr.setImmersionMode(xrImmersionMode: .mixed)

            let game = CubeGame(frame: model.session.frame, poses: model.poses, controls: model.controls)
            CubeHolder.shared.game = game
            game.start()
            xr.setupCallbacks(
                gameUpdate: { deltaTime in game.update(deltaTime: deltaTime) },
                handleInput: {}
            )

            let coordinator = model.coordinator
            let thread = Thread {
                xr.start()
                xr.runLoop()
                // The layer was invalidated: the space closed. Release the engine
                // now (no deferred teardown: nothing finalizes once the loop has
                // returned) and tell the coordinator, so the next open starts clean.
                game.shutdown()
                let session = model.session
                Task { @MainActor in
                    session.anchors.detach()
                    CubeHolder.shared.release()
                    coordinator.spaceDidTearDown()
                }
            }
            thread.name = "XR Render Thread"
            thread.qualityOfService = .userInteractive
            CubeHolder.shared.renderThread = thread
            thread.start()
        }
        .sharePlayFrame(model.session)
    }
}
