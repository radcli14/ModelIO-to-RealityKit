//
//  Entity+Write.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 5/25/26.
//

import Foundation
import ModelIO
import RealityKit

enum ModelIOWriteError: Error, LocalizedError {
    case noMeshesFound
    case exportFailed(URL)

    var errorDescription: String? {
        switch self {
        case .noMeshesFound:
            return "No ModelEntity meshes found in the entity tree"
        case .exportFailed(let url):
            return "MDLAsset export to \(url.lastPathComponent) failed"
        }
    }
}

@MainActor public extension Entity {

    func writeMDLAsset(to url: URL) async throws {
        func collectModelEntities(_ entity: Entity) -> [ModelEntity] {
            var result: [ModelEntity] = []
            if let modelEntity = entity as? ModelEntity {
                result.append(modelEntity)
            }
            for child in entity.children {
                result.append(contentsOf: collectModelEntities(child))
            }
            return result
        }

        let modelEntities = collectModelEntities(self)
        guard !modelEntities.isEmpty else {
            throw ModelIOWriteError.noMeshesFound
        }

        let asset = MDLAsset()
        let allocator = MDLMeshBufferDataAllocator()

        for modelEntity in modelEntities {
            guard let models = modelEntity.model?.mesh.contents.models else { continue }
            for model in models {
                for part in model.parts {
                    let positions = part.positions.elements
                    guard !positions.isEmpty else { continue }

                    let normals = part.normals?.elements
                    let uvs = part.textureCoordinates?.elements
                    guard let triangleIndicesBuffer = part.triangleIndices else { continue }
                    let indexArray = triangleIndicesBuffer.elements

                    // Interleaved layout: float3 position (12) + float3 normal (12) + float2 uv (8) = 32 bytes
                    let vertexDescriptor = MDLVertexDescriptor()

                    let posAttr = MDLVertexAttribute()
                    posAttr.name = MDLVertexAttributePosition
                    posAttr.format = .float3
                    posAttr.offset = 0
                    posAttr.bufferIndex = 0

                    let normAttr = MDLVertexAttribute()
                    normAttr.name = MDLVertexAttributeNormal
                    normAttr.format = .float3
                    normAttr.offset = 12
                    normAttr.bufferIndex = 0

                    let uvAttr = MDLVertexAttribute()
                    uvAttr.name = MDLVertexAttributeTextureCoordinate
                    uvAttr.format = .float2
                    uvAttr.offset = 24
                    uvAttr.bufferIndex = 0

                    vertexDescriptor.attributes = NSMutableArray(array: [posAttr, normAttr, uvAttr])
                    let layout = MDLVertexBufferLayout()
                    layout.stride = 32
                    vertexDescriptor.layouts = NSMutableArray(array: [layout])

                    var vertexData = Data()
                    vertexData.reserveCapacity(positions.count * 32)

                    for i in 0..<positions.count {
                        let p = positions[i]
                        var xyz = (p.x, p.y, p.z)
                        withUnsafeBytes(of: &xyz) { vertexData.append(contentsOf: $0) }

                        let n: SIMD3<Float>
                        if let nArr = normals, nArr.count == positions.count {
                            n = nArr[i]
                        } else {
                            n = .zero
                        }
                        var nxyz = (n.x, n.y, n.z)
                        withUnsafeBytes(of: &nxyz) { vertexData.append(contentsOf: $0) }

                        let uv: SIMD2<Float>
                        if let uvArr = uvs, uvArr.count == positions.count {
                            uv = uvArr[i]
                        } else {
                            uv = .zero
                        }
                        var uvxy = (uv.x, uv.y)
                        withUnsafeBytes(of: &uvxy) { vertexData.append(contentsOf: $0) }
                    }

                    let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
                    let indexData = indexArray.withUnsafeBytes { Data($0) }
                    let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

                    let submesh = MDLSubmesh(
                        indexBuffer: indexBuffer,
                        indexCount: indexArray.count,
                        indexType: .uInt32,
                        geometryType: .triangles,
                        material: nil
                    )

                    let mdlMesh = MDLMesh(
                        vertexBuffer: vertexBuffer,
                        vertexCount: positions.count,
                        descriptor: vertexDescriptor,
                        submeshes: NSMutableArray(array: [submesh])
                    )

                    asset.add(mdlMesh)
                }
            }
        }

        let success = asset.export(to: url)
        guard success else {
            throw ModelIOWriteError.exportFailed(url)
        }
    }
}
