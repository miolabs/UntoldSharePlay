//
//  View+SharePlay.swift
//  UntoldSharePlay
//
//  A RealityView space in a group session. Its scene is the group's shared
//  frame AND ARKit's frame: the system moves a FaceTime participant's space
//  to its seat and reports the move through SwiftUI's
//  `immersiveSpaceDisplacement` (kilometres on the headsets), but ARKit's
//  origin moves with the space, so the device pose, the hands, planes and
//  anchors already arrive in the scene's coordinates. The modifier
//  therefore tells the frame the scene is the shared frame and applies
//  nothing of the displacement; it only logs it.
//
//  Measured with Oche on two Vision Pros over FaceTime (2026-11-15): the
//  displacement was pos (127.56, 0.00, -2549.16) m, yaw 7.4 degrees, the seat (the
//  system pose) (-0.32, 0.00, 1.76) m. A build that fed the displacement
//  into the frame, mapped its content by it and put the inverse on its
//  RealityKit root (what this file did until then) drew everything in the
//  right place and had a dart at (128.27, 1.15, -2547.30) while the hand
//  pinching it reported (0.46, 1.15, 1.92): undone from the displacement
//  the dart is at (0.46, 1.15, 1.94). The compensation cancels on screen
//  and leaves every ARKit input kilometres from the content.
//

#if os(visionOS)
    import simd
    import Spatial
    import SwiftUI

    public extension View {
        /// On the view of a RealityView immersive space: the scene is the
        /// group's shared frame (`SharedFrame.declareSceneIsSharedFrame`).
        /// The CompositorContent modifier of the same name is the engine
        /// path's and feeds the displacement as before.
        func sharePlayFrame(_ session: SharePlaySession) -> some View {
            modifier(SharePlayFrameModifier(session: session))
        }
    }

    @MainActor
    struct SharePlayFrameModifier: ViewModifier {
        @Environment(\.immersiveSpaceDisplacement) private var displacement
        let session: SharePlaySession

        func body(content: Content) -> some View {
            content
                .onAppear { session.frame.declareSceneIsSharedFrame() }
                .onChange(of: session.state) { _, state in
                    if state == .joined { session.frame.declareSceneIsSharedFrame() }
                }
                .onChange(of: displacement, initial: true) { _, current in
                    // For the record only: the scene and ARKit moved together.
                    SharePlayLog.info("immersiveSpaceDisplacement reported \(SharedFrame.describe(simd_float4x4(current))) (not applied: a RealityView scene is the shared frame)")
                }
        }
    }
#endif
