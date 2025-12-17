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
        property(with: mdlSemantic)?.cgColor
    }
    
    /// Get the texture sampler for this material and semantic, if available
    func getTextureSampler(mdlSemantic: MDLMaterialSemantic) -> MDLTextureSampler? {
        property(with: mdlSemantic)?.textureSamplerValue
    }
    
    /// Get the URL of a file (typically an image) associated with this property
    func getUrl(mdlSemantic: MDLMaterialSemantic) -> URL? {
        property(with: mdlSemantic)?.urlValue
    }
    
    /// Get the `MDLTexture` for this material and semantic, if available
    func getTexture(mdlSemantic: MDLMaterialSemantic) -> MDLTexture? {
        property(with: mdlSemantic)?.texture
    }
    
    /// Get the `CGImage` for this material and semantic, if available
    func getImage(mdlSemantic: MDLMaterialSemantic) -> CGImage? {
        property(with: mdlSemantic)?.cgImage
    }
    
    /// Get a texture resource representing an image, using ModelIO semantic to unpack from the `material.propery`, and RealityKit semantic to initialize the `TextureResource`.
    @MainActor func getTextureResource(
        mdlSemantic: MDLMaterialSemantic,
        rkSemantic: TextureResource.Semantic
    ) async -> TextureResource? {
        await property(with: mdlSemantic)?.getTextureResource(rkSemantic: rkSemantic)
    }
    
    
    /// Attempts to extract the Base Color, prioritizing texture, then numeric value.
    @MainActor func getPbrBaseColor() async -> PhysicallyBasedMaterial.BaseColor? {
        guard let baseColorProperty = property(with: .baseColor) else { return nil }
        
        // Check for a texture map (file reference), or a numeric value.
        if let resource = await baseColorProperty.getTextureResource(rkSemantic: .color) {
            return .init(texture: .init(resource))
        }
        
        // Otherwise return the constant color
        let color = baseColorProperty.cgColor
        return .init(tint: .init(red: color[0], green: color[1], blue: color[2], alpha: color[3]))
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
        if let resource = await roughnessProperty?.getTextureResource(rkSemantic: .raw) {
            return .init(texture: .init(resource))
        } else if let resource = await specularProperty?.getTextureResource(rkSemantic: .raw) {
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
        guard let metallicProperty = property(with: .metallic) else { return nil }
        if let resource = await metallicProperty.getTextureResource(rkSemantic: .raw) {
            return .init(texture: .init(resource))
        }
        return .init(floatLiteral: metallicProperty.floatValue)
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
