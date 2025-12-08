//
//  MDLAsset+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/5/25.
//

import Foundation
import ModelIO
import RealityKit


@MainActor public extension MDLAsset {
    
    /// An array of RealityKit `MeshDescriptor` derived from the meshes in this model
    var meshDescriptors: [MeshDescriptor] {
        meshes.flatMap { $0.descriptors }
    }
    
    /// Asynchrnously onbtain a RealityKit `MeshResource` derived from the meshes in this model
    func getMeshResource() async -> MeshResource? {
        do {
            let sendableDescriptors = UnsafeSendableDescriptors(descriptors: meshDescriptors)
            return try await MeshResource(from: sendableDescriptors.descriptors)
        } catch {
            print("MDLAsset.getMeshResource() failed because \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Any array of RealityKit materials derived from data in the submeshes
    func getMaterials() async -> [any RealityKit.Material] {
        var result = [any RealityKit.Material]()
        for mesh in meshes {
            for submesh in mesh.submeshArray {
                if let material = await submesh.material?.getPbrMaterial() {
                    result.append(material)
                }
            }
        }
        return result
    }

    /// Asynchronously obtain a `ModelEntity` based on the mesh resoources and materials contained in this asset
    func getModelEntity() async -> ModelEntity? {
        let materials = await getMaterials()
        guard let meshResource = await getMeshResource() else { return nil }
        return ModelEntity(mesh: meshResource, materials: materials)
    }
    
    
    // TODO: I don't like the wrappers below, but it was a correction for "sending self.materials risks causing data races"

    /// Wrapper to make non-Sendable descriptors transferable across actor boundaries
    private struct UnsafeSendableDescriptors: @unchecked Sendable {
        let descriptors: [MeshDescriptor]
    }
}

