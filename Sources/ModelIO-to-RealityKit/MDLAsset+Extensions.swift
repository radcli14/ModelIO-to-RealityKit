//
//  MDLAsset+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/5/25.
//

import Foundation
import ModelIO
import RealityKit


public extension MDLAsset {
    private var meshDescriptors: [MeshDescriptor] {
        meshes.map { $0.descriptor }
    }
    
    private func getMeshResource() async -> MeshResource? {
        do {
            return try await MeshResource(from: meshDescriptors)
        } catch {
            print("MDLAsset.getMeshResource() failed because \(error.localizedDescription)")
            return nil
        }
    }
    
    var materials: [any RealityKit.Material] {
        meshes.flatMap { mesh in
            mesh.submeshArray.compactMap { submesh in
                submesh.pbrMaterial
            }
        }
    }

    func getModelEntity() async -> ModelEntity? {
        guard let meshResource = await getMeshResource() else { return nil }
        return await ModelEntity(mesh: meshResource, materials: materials)
    }
    
    func summary() {
        //meshes.map { material}
    }
}
