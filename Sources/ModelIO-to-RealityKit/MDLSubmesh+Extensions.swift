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
    
    /// The array of indices defining face connectivity, upcast to UInt32.
    var indices: [UInt32] {
        var result: [UInt32] = []
        indexData.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            switch self.indexType {
            case .uint8:
                let p = base.assumingMemoryBound(to: UInt8.self)
                for i in 0..<indexCount { result.append(UInt32(p[i])) }
            case .uint16:
                let p = base.assumingMemoryBound(to: UInt16.self)
                for i in 0..<indexCount { result.append(UInt32(p[i])) }
            case .uint32:
                let p = base.assumingMemoryBound(to: UInt32.self)
                for i in 0..<indexCount { result.append(p[i]) }
            default:
                print("[RealityKitFormats] MDLSubmesh: unsupported indexType \(self.indexType.rawValue) — submesh will be skipped")
            }
        }
        return result
    }
    
    @MainActor var primitives: MeshDescriptor.Primitives? {
        switch geometryType {
        case .triangles:
            return .triangles(indices)

        case .triangleStrips:
            // Convert triangle strip to an indexed triangle list.
            // Odd-numbered triangles have their first two indices swapped to maintain
            // consistent CCW winding across the strip.
            let src = indices
            guard src.count >= 3 else { return nil }
            var tri: [UInt32] = []
            tri.reserveCapacity((src.count - 2) * 3)
            for i in 0..<(src.count - 2) {
                if i % 2 == 0 {
                    tri += [src[i], src[i + 1], src[i + 2]]
                } else {
                    tri += [src[i + 1], src[i], src[i + 2]]
                }
            }
            print("[RealityKitFormats] MDLSubmesh: triangleStrip \(src.count) indices → \(tri.count / 3) triangles")
            return .triangles(tri)

        case .quads:
            // Fan-triangulate each quad: (v0,v1,v2) + (v0,v2,v3).
            let src = indices
            var tri: [UInt32] = []
            tri.reserveCapacity(src.count / 4 * 6)
            for i in stride(from: 0, to: src.count - 3, by: 4) {
                tri += [src[i], src[i + 1], src[i + 2],
                        src[i], src[i + 2], src[i + 3]]
            }
            print("[RealityKitFormats] MDLSubmesh: quads with \(src.count / 4) quads → \(tri.count / 3) triangles")
            return .triangles(tri)

        case .lines, .points:
            print("[RealityKitFormats] MDLSubmesh: geometry type \(geometryType) is not a surface — skipping")
            return nil

        case .variableTopology:
            print("[RealityKitFormats] MDLSubmesh: variableTopology not yet supported — skipping submesh")
            return nil

        @unknown default:
            print("[RealityKitFormats] MDLSubmesh: unknown geometry type \(geometryType.rawValue) — skipping")
            return nil
        }
    }
}


