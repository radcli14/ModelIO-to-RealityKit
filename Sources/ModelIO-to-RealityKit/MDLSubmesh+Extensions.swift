//
//  File.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/5/25.
//

import Foundation
import ModelIO
import RealityKit
import UIKit

/// A single `MDLMesh` can be composed of one or more `MDLSubmesh` instances.
/// Here is where we find the indices that define face connectivity for the vertices defined at the `MDLMesh` level.
/// Each submesh represents a distinct section of the geometry that uses a single material.
public extension MDLSubmesh {
    
    // MARK: - Mesh Indices
    
    var indexData: Data {
        return Data(bytes: indexBuffer.map().bytes, count: indexBuffer.length)
    }
    
    /// The array of indices defining face connectivity
    var indices: [UInt32] {
        var result: [UInt32] = []

        // Access the raw memory pointer of the index data
        indexData.withUnsafeBytes { (bufferPointer) in
            guard let baseAddress = bufferPointer.baseAddress else { return }

            switch self.indexType {
            case .uint16:
                // Data is 16-bit (UInt16), so we read and convert to UInt32
                let pointer = baseAddress.assumingMemoryBound(to: UInt16.self)
                for i in 0..<indexCount {
                    // Read the 16-bit index and cast it up to 32-bit
                    result.append(UInt32(pointer[i]))
                }
            
            case .uint32:
                // Data is already 32-bit (UInt32)
                let pointer = baseAddress.assumingMemoryBound(to: UInt32.self)
                for i in 0..<indexCount {
                    result.append(pointer[i])
                }
            
            default:
                // Handle unsupported types (e.g., .invalid)
                print("MDLSubmesh indexType \(self.indexType.rawValue) not supported for unpacking indices.")
                return
            }
        }
        
        return result
    }
    
    @MainActor var primitives: MeshDescriptor.Primitives? {
        var geometryString = ""
        switch geometryType {
        case .triangles: return .triangles(indices)
        case .quads: return .trianglesAndQuads(triangles: [], quads: indices)
        case .variableTopology: geometryString = "variableTopology"
        case .triangleStrips: geometryString = "triangleStrips"
        case .lines: geometryString = "lines"
        case .points: geometryString = "points"
        @unknown default:
            geometryString = "???"
        }
        print("MDLSubmesh geometryType: \(geometryString) is unknown or not handled, returning nil")
        return nil
    }
    
    // MARK: - Material
    
    /// Extract the `UIColor` representation for this material given the specified ModelIO semantic
    func getColor(mdlSemantic: MDLMaterialSemantic) -> UIColor? {
        if let material: MDLMaterial,
            let property: MDLMaterialProperty = material.property(with: mdlSemantic) {
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
    
    /// Get a texture resource representing an image, using ModelIO semantic to unpack from the `material.propery`, and RealityKit semantic to initialize the `TextureResource`.
    @MainActor func getTextureResource(
        mdlSemantic: MDLMaterialSemantic,
        rkSemantic: TextureResource.Semantic
    ) -> TextureResource? {
        if let material: MDLMaterial,
            let property: MDLMaterialProperty = material.property(with: mdlSemantic),
            let sampler: MDLTextureSampler = property.textureSamplerValue,
            let texture: MDLTexture = sampler.texture,
            let image: CGImage = texture.imageFromTexture()?.takeRetainedValue(),
            let resource = try? TextureResource(image: image, options: .init(semantic: rkSemantic)) {
            
            // Successfully obtained the resource, return it
            return resource
        }
        return nil
    }
    
    // TODO: Lots here, need to complete the import settings for materials
    
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
        let roughnessProperty = material?.property(with: .roughness)
        let specularProperty = material?.property(with: .specularExponent)
        if let value = specularProperty?.floatValue {
            return .init(floatLiteral: sqrt(2.0 / (value + 2.0)))
        } else if let resource = getTextureResource(mdlSemantic: .roughness, rkSemantic: .raw) {
            return .init(texture: .init(resource))
        } else if let value = roughnessProperty?.floatValue {
            return .init(floatLiteral: value)
        }
        return nil
    }
    
    /// Create the PBR material's metallic image or float value
    @MainActor var pbrMetallic: PhysicallyBasedMaterial.Metallic? {
        let metallicProperty = material?.property(with: .metallic)
        if let resource = getTextureResource(mdlSemantic: .metallic, rkSemantic: .raw) {
            return .init(texture: .init(resource))
        } else if let value = metallicProperty?.floatValue {
            return .init(floatLiteral: value)
        }
        return nil
    }
    
    /// The `PhysicallyBasedMaterial` representation of the material included in the submesh
    @MainActor var pbrMaterial: PhysicallyBasedMaterial? {
        guard material != nil else { return nil }
        
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


