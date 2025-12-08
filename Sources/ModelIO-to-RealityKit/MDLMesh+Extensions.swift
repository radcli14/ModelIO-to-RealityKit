//
//  MDLMesh+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/5/25.
//

import Foundation
import ModelIO
import RealityKit


public extension MDLMesh {
    
    /// An array of `MDLVertexAttribute` unpacked from the `vertexDescriptor.attributes` which is a `NSMutableArray` in the built-in `MDLMesh`
    private var vertexDescriptorAttributes: [MDLVertexAttribute] {
        vertexDescriptor.attributes.compactMap {
            $0 as? MDLVertexAttribute
        }
    }
    
    // MARK: - Vertex Positions
    
    /// The `MDLVertexAttribute` that contains the offset variable used for unpacking the position buffer
    private var positionAttribute: MDLVertexAttribute? {
        return vertexDescriptorAttributes.first {
            $0.name == MDLVertexAttributePosition
        }
    }
    
    /// The `MDLMeshBuffer` that contains the buffer index and vertex position data
    private var positionBuffer: MDLMeshBuffer? {
        guard let index = positionAttribute?.bufferIndex else { return nil }
        return vertexBuffers[index]
    }
    
    /// The `MDLVertexBufferLayout` which is used to get the stride
    private var vertexBufferLayout: MDLVertexBufferLayout? {
        guard let index = positionAttribute?.bufferIndex else { return nil }
        return vertexDescriptor.layouts[index] as? MDLVertexBufferLayout
    }
    
    /// The array of 3D vertex positions representing points in the mesh
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
    
    // MARK: - UV Coordinates
    
    /// The `MDLVertexAttribute` that contains the offset variable used for unpacking the UV coordinate buffer
    private var textureCoordinateAttribute: MDLVertexAttribute? {
        return vertexDescriptorAttributes.first {
            $0.name == MDLVertexAttributeTextureCoordinate
        }
    }
    
    /// The `MDLMeshBuffer` that contains the buffer index and vertex position data
    private var textureCoordinateBuffer: MDLMeshBuffer? {
        guard let index = textureCoordinateAttribute?.bufferIndex else { return nil }
        return vertexBuffers[index]
    }
    
    /// The `MDLVertexBufferLayout` which is used to get the stride
    private var textureCoordinateBufferLayout: MDLVertexBufferLayout? {
        guard let index = textureCoordinateAttribute?.bufferIndex else { return nil }
        return vertexDescriptor.layouts[index] as? MDLVertexBufferLayout
    }
    
    var textureCoordinates: [SIMD2<Float>] {
        // Find the attribute for texture coordinates
        guard let textureCoordinateAttribute,
                let textureCoordinateBuffer,
                let textureCoordinateBufferLayout else {
            return []
        }

        let stride = textureCoordinateBufferLayout.stride
        let rawPointer = textureCoordinateBuffer.map().bytes
        let vertexCount = textureCoordinateBuffer.length / stride
        let offset = textureCoordinateAttribute.offset
        
        var result = [SIMD2<Float>]()
        for i in 0..<vertexCount {
            let vertexStart = rawPointer.advanced(by: i * stride)
            let uvStart = vertexStart.advanced(by: offset)
            let floatPointer = uvStart.assumingMemoryBound(to: Float.self)
            result.append(.init(floatPointer[0], floatPointer[1]))
        }
        return result
    }
    
    // MARK: - Normals
    
    // MARK: - Submesh
    
    /// An array of `MDLSubmesh` unpacked from the `submeshes` variable which is a `NSMutableArray` in the built-in `MDLMesh`
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
    
    // MARK: - RealityKit
    
    /// An array of `MeshDescriptor` derived from the `positions` array and primitive indices contained in the `submeshes`
    @MainActor var descriptors: [MeshDescriptor] {
        
        // Get the computed property first, so it isn't computed multiple times inside the map
        let positions = positions
        let textureCoordinates = textureCoordinates
        guard !positions.isEmpty else { return [] }

        // Map the mesh descriptors from the vertex positions, and primitives in the submesh
        return submeshArray.map { submesh in
            var descriptor = MeshDescriptor(name: name)
            descriptor.positions = .init(positions)
            if textureCoordinates.count == positions.count {
                descriptor.textureCoordinates = .init(textureCoordinates)
            }
            descriptor.primitives = submesh.primitives
            return descriptor
        }
    }
}
