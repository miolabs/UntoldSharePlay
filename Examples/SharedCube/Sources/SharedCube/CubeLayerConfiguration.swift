//
//  CubeLayerConfiguration.swift
//  SharedCube
//

import CompositorServices
import SwiftUI

/// The engine's usual layer: a dedicated layout, sRGB colour, no foveation.
struct CubeLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
    }
}
