//
//  File.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/5/25.
//

import Foundation
import ModelIO
import RealityKit

/// A single `MDLMesh` can be composed of one or more `MDLSubmesh` instances.
/// Here is where we find the indices that define face connectivity for the vertices defined at the `MDLMesh` level.
/// Each submesh represents a distinct section of the geometry that uses a single material.
extension MDLSubmesh {
    
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
    
    var primitives: MeshDescriptor.Primitives? {
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
    
    // TODO: Lots here, need to complete the import settings for materials
    
    /// Attempts to extract the Base Color, prioritizing texture, then numeric value.
    var pbrBaseColor: PhysicallyBasedMaterial.BaseColor? {
        let baseColorProperty = material?.property(with: .baseColor)
        
        // Check for a texture map (file reference), or a numeric value.
        if let _ = baseColorProperty?.textureSamplerValue {
            // TODO: build from texture sampler
            return nil
        } else if let color = baseColorProperty?.float4Value {
            return .init(tint: .init(
                red: CGFloat(color[0]),
                green: CGFloat(color[1]),
                blue: CGFloat(color[2]),
                alpha: CGFloat(color[3])
            ))
        }
        return nil
    }
    
    var pbrNormal: PhysicallyBasedMaterial.Normal? {
        return nil
    }
    
    var pbrRoughness: PhysicallyBasedMaterial.Roughness? {
        // TODO: add some better logic for when to use roughness vs specular, I'm using it the way I am here because it seemed lost in the Blender .obj file export
        let roughnessProperty = material?.property(with: .roughness)
        let specularProperty = material?.property(with: .specularExponent)
        if let value = specularProperty?.floatValue {
            let convertedRoughness = sqrt(2.0 / (value + 2.0))
            print("specularExponent: \(value), convertedRoughness: \(convertedRoughness)")
            return .init(floatLiteral: convertedRoughness)
        } else if let _ = roughnessProperty?.textureSamplerValue {
            // TODO: build from texture sampler
        } else if let value = roughnessProperty?.floatValue {
            print("roughness: \(value)")
            return .init(floatLiteral: value)
        }
        return nil
    }
    
    var pbrMetallic: PhysicallyBasedMaterial.Metallic? {
        let metallicProperty = material?.property(with: .metallic)
        if let _ = metallicProperty?.textureSamplerValue {
            // TODO: build from texture sampler
        } else if let value = metallicProperty?.floatValue {
            print("metallic: \(value)")
            return .init(floatLiteral: value)
        }
        return nil
    }
    
    /// The `PhysicallyBasedMaterial` representation of the material included in the submesh
    var pbrMaterial: PhysicallyBasedMaterial? {
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
    
    func printSummary() {
        print("MDLSubmesh.printSummary()")
        print(" - indexType: \(indexType)")
        print(" - indexData: \(indexData)")
        print(" - geometryType: triangles? \(geometryType == MDLGeometryType.triangles)")
        //print(" - primitives: \(primitives)")
        print(" - indexCount: \(indexCount)")
        
        let indices = self.indices
        print(" - total indices: \(indices.count)")
        
        if geometryType == .triangles {
            let triangleCount = indices.count / 3
            print(" - triangle count: \(triangleCount)")
            
            // Print first few triangles to see the structure
            let samplesToShow = min(5, triangleCount)
            print(" - first \(samplesToShow) triangles:")
            for i in 0..<samplesToShow {
                let idx = i * 3
                let v0 = indices[idx]
                let v1 = indices[idx + 1]
                let v2 = indices[idx + 2]
                print("   Triangle \(i): [\(v0), \(v1), \(v2)]")
            }
        }
        
        print(" - material: \(material)")
    }
}


