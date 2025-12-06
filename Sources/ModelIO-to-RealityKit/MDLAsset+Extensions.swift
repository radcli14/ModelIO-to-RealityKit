//
//  MDLAsset+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/5/25.
//

import Foundation
import ModelIO
@preconcurrency import RealityKit


public extension MDLAsset {
    
    /// An array of RealityKit `MeshDescriptor` derived from the meshes in this model
    var meshDescriptors: [MeshDescriptor] {
        meshes.map { $0.descriptor }
    }
    
    /// Asynchrnously onbtain a RealityKit `MeshResource` derived from the meshes in this model
    func getMeshResource() async -> MeshResource? {
        do {
            return try await MeshResource(from: meshDescriptors)
        } catch {
            print("MDLAsset.getMeshResource() failed because \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Any array of RealityKit materials derived from data in the submeshes
    var materials: [any RealityKit.Material] {
        meshes.flatMap { mesh in
            mesh.submeshArray.compactMap { submesh in
                submesh.pbrMaterial
            }
        }
    }

    /// Asynchronously obtain a `ModelEntity` based on the mesh resoources and materials contained in this asset
    func getModelEntity() async -> ModelEntity? {
        // Wrap materials in a Sendable wrapper to cross actor boundary
        let sendableMaterials = UnsafeSendableMaterials(materials: materials)
        guard let meshResource = await getMeshResource() else { return nil }
        return await ModelEntity(mesh: meshResource, materials: sendableMaterials.materials)
    }
    
    // TODO: I don't like the wrapper below, but it was a correction for "sending self.materials risks causing data races"
    
    /// Wrapper to make non-Sendable materials transferable across actor boundaries
    private struct UnsafeSendableMaterials: @unchecked Sendable {
        let materials: [any RealityKit.Material]
    }
}

