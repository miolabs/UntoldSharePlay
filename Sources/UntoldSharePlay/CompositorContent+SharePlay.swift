//
//  CompositorContent+SharePlay.swift
//  UntoldSharePlay
//
//  The system moves a shared immersive space by `immersiveSpaceDisplacement`
//  so the group's origin lands in a good place for everyone; the device
//  anchor, the hands and the controllers stay in the un-displaced ARKit frame.
//  This modifier feeds the displacement to the session's frame, which applies
//  it to every pose that crosses the wire. A Compositor Services space the
//  system leaves where it is (identity, as the headsets showed): then the
//  frame's placement comes from the system's pose of the device instead.
//

#if os(visionOS)
    import simd
    import Spatial
    import SwiftUI

    @available(visionOS 26.0, *)
    public extension CompositorContent {
        /// Feeds the immersive space's displacement into `session.frame`.
        func sharePlayFrame(_ session: SharePlaySession) -> some CompositorContent {
            SharePlayFramedContent(session: session, content: self)
        }
    }

    @available(visionOS 26.0, *)
    struct SharePlayFramedContent<Content: CompositorContent>: CompositorContent {
        @Environment(\.immersiveSpaceDisplacement) private var displacement

        let session: SharePlaySession
        let content: Content

        var body: some CompositorContent {
            content
                .onChange(of: displacement, initial: true) { previous, current in
                    let matrix = simd_float4x4(current)
                    let summary = SharedFrame.describe(matrix)
                    session.frame.setImmersiveSpaceDisplacement(matrix, summary: summary)
                    SharePlayLog.info(
                        "immersiveSpaceDisplacement → \(summary)"
                            + (previous == current ? "" : " (was \(SharedFrame.describe(simd_float4x4(previous))))")
                    )
                }
        }
    }
#endif
