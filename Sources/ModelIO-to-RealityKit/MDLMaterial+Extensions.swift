//
//  MDLMaterial+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/8/25.
//

import Foundation
import ModelIO
import RealityKit

extension MDLMaterial {
    
    /// Extract the `UIColor` representation for this material given the specified ModelIO semantic
    func getColor(mdlSemantic: MDLMaterialSemantic) -> [CGFloat]? {
        if let property: MDLMaterialProperty = property(with: mdlSemantic) {
            let color = property.float4Value
            var result = [CGFloat](repeating: 0, count: 4)
            for k in 0..<4 {
                result[k] = CGFloat(color[k])
            }
            return result
        }
        return nil
    }
    
    /// Get the texture sampler for this material and semantic, if available
    func getTextureSampler(mdlSemantic: MDLMaterialSemantic) -> MDLTextureSampler? {
        guard let materialProperty = property(with: mdlSemantic) else {
            //print("Failed to get property(with: \(mdlSemantic))")
            return nil
        }
        guard let sampler = materialProperty.textureSamplerValue else {
            //print("Failed to getTextureSampler(mdlSemantic: \(mdlSemantic))")
            return nil
        }
        return sampler
    }
    
    /// Get the URL of a file (typically an image) associated with this property
    func getUrl(mdlSemantic: MDLMaterialSemantic) -> URL? {
        guard let materialProperty = property(with: mdlSemantic) else {
            //print("Failed to get property(with: \(mdlSemantic))")
            return nil
        }
        guard let url = materialProperty.urlValue else {
            //print("Failed to getUrl(with: \(mdlSemantic))")
            return nil
        }
        return url
    }
    
    /// Get the `MDLTexture` for this material and semantic, if available
    func getTexture(mdlSemantic: MDLMaterialSemantic) -> MDLTexture? {
        guard let sampler = getTextureSampler(mdlSemantic: mdlSemantic) else {
            return nil
        }
        guard let texture = sampler.texture else {
            //print("Failed to getTexture(mdlSemantic: \(mdlSemantic))")
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
            //print("Failed to getImage(mdlSemantic: \(mdlSemantic))")
            return nil
        }
        return image
    }
    
    /// Get a texture resource representing an image, using ModelIO semantic to unpack from the `material.propery`, and RealityKit semantic to initialize the `TextureResource`.
    @MainActor func getTextureResource(
        mdlSemantic: MDLMaterialSemantic,
        rkSemantic: TextureResource.Semantic
    ) async -> TextureResource? {
        
        // First try to load from a URL if it exists
        if let url = getUrl(mdlSemantic: mdlSemantic),
            let resource = try? await TextureResource(contentsOf: url) {
            print("Succeeded in getting a resource", resource, "from", url.lastPathComponent)
            return resource
        }
        
        // Else try from the texture sampler, though this never works
        guard let image = getImage(mdlSemantic: mdlSemantic) else {
            return nil
        }
        guard let resource = try? await TextureResource(image: image, options: .init(semantic: rkSemantic)) else {
            //print("Failed to getTextureResource(mdlSemantic: \(mdlSemantic), rkSemantic: \(rkSemantic)")
            return nil
        }
        return resource
    }
    
    
    /// Attempts to extract the Base Color, prioritizing texture, then numeric value.
    @MainActor func getPbrBaseColor() async -> PhysicallyBasedMaterial.BaseColor? {
        // Check for a texture map (file reference), or a numeric value.
        if let resource = await getTextureResource(mdlSemantic: .baseColor, rkSemantic: .color) {
            return .init(texture: .init(resource))
            
        // Otherwise check for the constant color
        } else if let color = getColor(mdlSemantic: .baseColor) {
            return .init(tint: .init(red: color[0], green: color[1], blue: color[2], alpha: color[3]))
        }
        return nil
    }
    
    /// Create the PBR material's normal image
    @MainActor func getPbrNormal() async -> PhysicallyBasedMaterial.Normal? {
        if let resource = await getTextureResource(mdlSemantic: .tangentSpaceNormal, rkSemantic: .normal) {
            return .init(texture: .init(resource))
        }
        return nil
    }
    
    /// Create the PBR material's roughness image or float value
    @MainActor func getPbrRoughness() async -> PhysicallyBasedMaterial.Roughness? {
        // TODO: add some better logic for when to use roughness vs specular, I'm using it the way I am here because it seemed lost in the Blender .obj file export
        let roughnessProperty = property(with: .roughness)
        let specularProperty = property(with: .specularExponent)
        if let resource = await getTextureResource(mdlSemantic: .roughness, rkSemantic: .raw) {
            return .init(texture: .init(resource))
        } else if let resource = await getTextureResource(mdlSemantic: .specularExponent, rkSemantic: .raw) {
            return .init(texture: .init(resource))
        } else if let value = specularProperty?.floatValue {
            return .init(floatLiteral: sqrt(2.0 / (value + 2.0)))
        } else if let value = roughnessProperty?.floatValue {
            return .init(floatLiteral: value)
        }
        return nil
    }
    
    /// Create the PBR material's metallic image or float value
    @MainActor func getPbrMetallic() async -> PhysicallyBasedMaterial.Metallic? {
        let metallicProperty = property(with: .metallic)
        if let resource = await getTextureResource(mdlSemantic: .metallic, rkSemantic: .raw) {
            return .init(texture: .init(resource))
        } else if let value = metallicProperty?.floatValue {
            return .init(floatLiteral: value)
        }
        return nil
    }
    
    /// The `PhysicallyBasedMaterial` representation of the material included in the submesh
    @MainActor func getPbrMaterial() async -> PhysicallyBasedMaterial? {
        
        // For debugging, I'm using this to try to find which semantics contain image urls
        /*print("roughness", MDLMaterialSemantic.roughness.rawValue, MDLMaterialSemantic.specularExponent.rawValue)
        for semantic in Self.allSemantics {
            if let url = getUrl(mdlSemantic: semantic) {
                print(semantic.rawValue, url)
            }
        }*/
        
        var pbrMaterial = PhysicallyBasedMaterial()
        if let pbrBaseColor = await getPbrBaseColor() {
            pbrMaterial.baseColor = pbrBaseColor
        }
        if let pbrNormal = await getPbrNormal() {
            pbrMaterial.normal = pbrNormal
        }
        if let pbrRoughness = await getPbrRoughness() {
            pbrMaterial.roughness = pbrRoughness
        }
        if let pbrMetallic = await getPbrMetallic() {
            pbrMaterial.metallic = pbrMetallic
        }

        return pbrMaterial
    }
    
    
    static let allSemantics: [MDLMaterialSemantic] = [
        .ambientOcclusion,
        .ambientOcclusionScale,
        .anisotropic,
        .anisotropicRotation,
        .baseColor,
        .bump,
        .clearcoat,
        .clearcoatGloss,
        .displacement,
        .displacementScale,
        .emission,
        .interfaceIndexOfRefraction,
        .materialIndexOfRefraction,
        .metallic,
        .none,
        .objectSpaceNormal,
        .opacity,
        .roughness,
        .sheen,
        .sheenTint,
        .specular,
        .specularExponent,
        .specularTint,
        .subsurface,
        .tangentSpaceNormal,
        .userDefined
    ]
}
