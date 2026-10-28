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
        .defaultSize(width: 560, height: 560)

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
            // `--open-space` opens the immersive space at launch (simulator runs).
            if CommandLine.arguments.contains("--open-space") {
                model.coordinator.open(reason: "launch argument")
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shared Cube").font(.largeTitle).bold()
            SharePlayStatusView(model.session)
            Divider()
            HStack {
                Button("Open space") { model.coordinator.open(reason: "button") }
                    .disabled(model.coordinator.phase != .closed)
                Button("Close space") { model.coordinator.dismiss(reason: "button") }
                    .disabled(model.coordinator.phase != .open)
                Text("space: \(model.coordinator.phaseLabel)").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(model.controls.headSummary + " · \(model.controls.cubeCount) cube(s)").font(.caption)
            ForEach(model.session.others) { participant in
                Text("\(participant.id.uuidString.prefix(8)): \(model.session.frame.alignment(of: participant.id)) · \(model.session.frame.summary(of: participant.id))")
                    .font(.caption)
            }
            Text("anchors: \(model.session.anchors.summary) · displacement \(model.session.frame.displacementSummary)").font(.caption)
            HStack {
                Button("Sync (stand together, face the same way)") { model.controls.requestCalibration() }
                    .disabled(model.session.others.isEmpty)
                Text(model.controls.lastCalibration).font(.caption)
            }
            if let other = model.session.others.first, model.session.frame.alignment(of: other.id) == .manual {
                VStack {
                    Slider(value: Binding(get: { Double(nudge.x) }, set: { nudge.x = Float($0); model.session.frame.setNudge(nudge, for: other.id) }), in: -0.5 ... 0.5) { Text("side") }
                    Slider(value: Binding(get: { Double(nudge.y) }, set: { nudge.y = Float($0); model.session.frame.setNudge(nudge, for: other.id) }), in: -0.5 ... 0.5) { Text("forward") }
                }
            }
            Spacer()
        }
        .padding(32)
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
                game.shutdown()
                Task { @MainActor in
                    shutdownUntoldEngineXR(xr) {
                        CubeHolder.shared.xr = nil
                        CubeHolder.shared.game = nil
                        CubeHolder.shared.renderThread = nil
                        coordinator.spaceDidTearDown()
                    }
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
