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
}


