//
//  View+SharePlay.swift
//  UntoldSharePlay
//
//  A RealityView space in a group session: the system moves the space to
//  the participant's seat (kilometres from ARKit's origin, as visionOS
//  places group spaces) and reports it through SwiftUI's
//  `immersiveSpaceDisplacement`; the view feeds it into `session.frame`.
//  The headset runs of 2026-10-29 (Oche) showed the value flipping to
//  identity and back while the app's windows came and went, each flip
//  moving everything drawn in the local frame by that much, so while the
//  session is joined a real displacement is kept until a new real one
//  arrives; identity is taken once the session has ended.
//

#if os(visionOS)
    import simd
    import Spatial
    import SwiftUI

    public extension View {
        /// Feeds the immersive space's displacement into `session.frame`
        /// (the RealityView counterpart of the CompositorContent modifier).
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
                .onChange(of: displacement, initial: true) { previous, current in
                    let matrix = simd_float4x4(current)
                    let summary = SharedFrame.describe(matrix)
                    if matrix == matrix_identity_float4x4, session.state == .joined, session.frame.spaceDisplacement != matrix_identity_float4x4 {
                        SharePlayLog.info("immersiveSpaceDisplacement → identity while joined: kept \(SharedFrame.describe(session.frame.spaceDisplacement))")
                        return
                    }
                    session.frame.setImmersiveSpaceDisplacement(matrix, summary: summary)
                    SharePlayLog.info(
                        "immersiveSpaceDisplacement → \(summary)"
                            + (previous == current ? "" : " (was \(SharedFrame.describe(simd_float4x4(previous))))")
                    )
                }
                .onChange(of: session.state) { _, state in
                    // The session ended: the space is where the system left it.
                    if state == .idle, session.frame.spaceDisplacement != matrix_identity_float4x4 {
                        session.frame.setImmersiveSpaceDisplacement(simd_float4x4(displacement), summary: SharedFrame.describe(simd_float4x4(displacement)))
                    }
                }
        }
    }
#endif
