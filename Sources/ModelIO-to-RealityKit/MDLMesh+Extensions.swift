//
//  MDLMesh+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/5/25.
//

import Foundation
import ModelIO
import RealityKit


@MainActor public extension MDLMesh {
    private var vertexDescriptorAttributes: [MDLVertexAttribute] {
        vertexDescriptor.attributes.compactMap {
            $0 as? MDLVertexAttribute
        }
    }
    
    private var positionAttribute: MDLVertexAttribute? {
        return vertexDescriptorAttributes.first {
            $0.name == MDLVertexAttributePosition
        }
    }
    
    private var positionBuffer: MDLMeshBuffer? {
        guard let index = positionAttribute?.bufferIndex else { return nil }
        return vertexBuffers[index]
    }
    
    private var vertexBufferLayout: MDLVertexBufferLayout? {
        guard let index = positionAttribute?.bufferIndex else { return nil }
        return vertexDescriptor.layouts[index] as? MDLVertexBufferLayout
    }
    
    var positions: [SIMD3<Float>] {
        guard let positionBuffer, let vertexBufferLayout, let positionAttribute else {
            return []
        }
        // Get the data that informs how to unpack the buffer
        let stride = vertexBufferLayout.stride
        let rawPointer = positionBuffer.map().bytes
        let vertexCount = positionBuffer.length / stride
        let offset = positionAttribute.offset

        var result = [SIMD3<Float>]()
        for i in 0 ..< vertexCount  {
            // Get the pointer associated with this vertex
            let vertexStart = rawPointer.advanced(by: i * stride)
            let positionStart = vertexStart.advanced(by: offset)
            let floatPointer = positionStart.assumingMemoryBound(to: Float.self)
            
            // Unpack this vertex position into the SIMD3<Float>
            result.append(.init(
                x: floatPointer[0],
                y: floatPointer[1],
                z: floatPointer[2]
            ))
        }
        
        return result
    }
    
    // TODO: add primitives
    var descriptor: MeshDescriptor {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = .init(positions)
        let indices = submeshArray.compactMap { $0.indices }.flatMap { $0 }
        
        descriptor.primitives = .triangles(indices)
        return descriptor
    }
    
    var submeshArray: [MDLSubmesh] {
        guard let submeshes else { return [] }
        var result = [MDLSubmesh]()
        for i in 0 ..< submeshes.count {
            if let submesh = submeshes[i] as? MDLSubmesh {
                result.append(submesh)
            }
        }
        return result
    }
}
