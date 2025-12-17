//
//  MDLMaterialProperty+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/17/25.
//

import Foundation
import ModelIO
import RealityKit

extension MDLMaterialProperty {
    /// Extract the color representation for this material property as an array of `CGFloat`
    var cgColor: [CGFloat] {
        [CGFloat(float4Value[0]), CGFloat(float4Value[1]), CGFloat(float4Value[2]), CGFloat(float4Value[3])]
    }
    
    /// Get the `MDLTexture` for this material property, if available
    var texture: MDLTexture? {
        guard let texture = textureSamplerValue?.texture else {
            //print("Failed to getTexture(mdlSemantic: \(mdlSemantic))")
            return nil
        }
        return texture
    }
    
    /// Get the `CGImage` for this material property, if available
    var cgImage: CGImage? {
        guard let image = texture?.imageFromTexture()?.takeRetainedValue() else {
            //print("Failed to getImage(mdlSemantic: \(mdlSemantic))")
            return nil
        }
        return image
    }
    
    // MARK: - RealityKit
    
    /// Get a texture resource representing an image, using RealityKit semantic to initialize the `TextureResource`.
    @MainActor
    func getTextureResource(rkSemantic: TextureResource.Semantic) async -> TextureResource? {
        // First try to load from a URL if it exists
        if let urlValue, let resource = try? await TextureResource(contentsOf: urlValue) {
            print("Succeeded in getting a resource", resource, "from", urlValue.lastPathComponent)
            return resource
        }
        
        // Else try from the texture sampler, though this never works
        guard let cgImage else {
            return nil
        }
        guard let resource = try? await TextureResource(image: cgImage, options: .init(semantic: rkSemantic)) else {
            //print("Failed to getTextureResource(mdlSemantic: \(mdlSemantic), rkSemantic: \(rkSemantic)")
            return nil
        }
        return resource
    }
}
