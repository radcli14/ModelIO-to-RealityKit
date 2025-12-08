//
//  MDLMaterial+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/8/25.
//

import Foundation
import ModelIO
import RealityKit
import UIKit

extension MDLMaterial {
    
    /// Extract the `UIColor` representation for this material given the specified ModelIO semantic
    func getColor(mdlSemantic: MDLMaterialSemantic) -> UIColor? {
        if let property: MDLMaterialProperty = property(with: mdlSemantic) {
            let color = property.float4Value
            return .init(
                red: CGFloat(color[0]),
                green: CGFloat(color[1]),
                blue: CGFloat(color[2]),
                alpha: CGFloat(color[3])
            )
        }
        return nil
    }
    
    /// Get the texture sampler for this material and semantic, if available
    func getTextureSampler(mdlSemantic: MDLMaterialSemantic) -> MDLTextureSampler? {
        guard let materialProperty = property(with: mdlSemantic) else {
            print("Failed to get property(with: \(mdlSemantic))")
            return nil
        }
        guard let sampler = materialProperty.textureSamplerValue else {
            print("Failed to getTextureSampler(mdlSemantic: \(mdlSemantic))")
            return nil
        }
        return sampler
    }
    
    /// Get the `MDLTexture` for this material and semantic, if available
    func getTexture(mdlSemantic: MDLMaterialSemantic) -> MDLTexture? {
        guard let sampler = getTextureSampler(mdlSemantic: mdlSemantic) else {
            return nil
        }
        guard let texture = sampler.texture else {
            print("Failed to getTexture(mdlSemantic: \(mdlSemantic))")
            return nil
        }
        return texture
    }
    
    /// Get the `CGImage` for this material and semantic, if available
    func getImage(mdlSemantic: MDLMaterialSemantic) -> CGImage? {
        guard let texture = getTexture(mdlSemantic: mdlSemantic) else {
            return nil
        }
        guard let image = texture.imageFromTexture()?.takeRetainedValue() else {
            print("Failed to getImage(mdlSemantic: \(mdlSemantic))")
            return nil
        }
        return image
    }
    
    /// Get a texture resource representing an image, using ModelIO semantic to unpack from the `material.propery`, and RealityKit semantic to initialize the `TextureResource`.
    @MainActor func getTextureResource(
        mdlSemantic: MDLMaterialSemantic,
        rkSemantic: TextureResource.Semantic
    ) -> TextureResource? {
        guard let image = getImage(mdlSemantic: mdlSemantic) else {
            return nil
        }
        guard let resource = try? TextureResource(image: image, options: .init(semantic: rkSemantic)) else {
            print("Failed to getTextureResource(mdlSemantic: \(mdlSemantic), rkSemantic: \(rkSemantic)")
            return nil
        }
        return nil
    }
    
    
    /// Attempts to extract the Base Color, prioritizing texture, then numeric value.
    @MainActor var pbrBaseColor: PhysicallyBasedMaterial.BaseColor? {
        // Check for a texture map (file reference), or a numeric value.
        if let resource = getTextureResource(mdlSemantic: .baseColor, rkSemantic: .color) {
            return .init(texture: .init(resource))
            
        // Otherwise check for the constant color
        } else if let color = getColor(mdlSemantic: .baseColor) {
            return .init(tint: color)
        }
        return nil
    }
    
    /// Create the PBR material's normal image
    @MainActor var pbrNormal: PhysicallyBasedMaterial.Normal? {
        if let resource = getTextureResource(mdlSemantic: .tangentSpaceNormal, rkSemantic: .normal) {
            return .init(texture: .init(resource))
        }
        return nil
    }
    
    /// Create the PBR material's roughness image or float value
    @MainActor var pbrRoughness: PhysicallyBasedMaterial.Roughness? {
        // TODO: add some better logic for when to use roughness vs specular, I'm using it the way I am here because it seemed lost in the Blender .obj file export
        let roughnessProperty = property(with: .roughness)
        let specularProperty = property(with: .specularExponent)
        if let resource = getTextureResource(mdlSemantic: .roughness, rkSemantic: .raw) {
            return .init(texture: .init(resource))
        } else if let value = specularProperty?.floatValue {
            return .init(floatLiteral: sqrt(2.0 / (value + 2.0)))
        } else if let value = roughnessProperty?.floatValue {
            return .init(floatLiteral: value)
        }
        return nil
    }
    
    /// Create the PBR material's metallic image or float value
    @MainActor var pbrMetallic: PhysicallyBasedMaterial.Metallic? {
        let metallicProperty = property(with: .metallic)
        if let resource = getTextureResource(mdlSemantic: .metallic, rkSemantic: .raw) {
            return .init(texture: .init(resource))
        } else if let value = metallicProperty?.floatValue {
            return .init(floatLiteral: value)
        }
        return nil
    }
    
    /// The `PhysicallyBasedMaterial` representation of the material included in the submesh
    @MainActor var pbr: PhysicallyBasedMaterial? {
        var pbrMaterial = PhysicallyBasedMaterial()
        if let pbrBaseColor {
            pbrMaterial.baseColor = pbrBaseColor
        }
        if let pbrNormal {
            pbrMaterial.normal = pbrNormal
        }
        if let pbrRoughness {
            pbrMaterial.roughness = pbrRoughness
        }
        if let pbrMetallic {
            pbrMaterial.metallic = pbrMetallic
        }

        return pbrMaterial
    }
}
