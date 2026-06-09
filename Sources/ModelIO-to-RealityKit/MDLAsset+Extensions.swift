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
    
    /// An array of RealityKit `MeshDescriptor` derived from the meshes in this model.
    /// NOTE: Does not set materialIndex — use `getModelEntity()` for correct multi-material meshes.
    var meshDescriptors: [MeshDescriptor] {
        meshes.flatMap { $0.descriptors }
    }

    /// Asynchronously obtain a RealityKit `MeshResource` derived from the meshes in this model.
    /// NOTE: Does not set materialIndex — use `getModelEntity()` for correct multi-material meshes.
    func getMeshResource() async throws -> MeshResource {
        let sendableDescriptors = UnsafeSendableDescriptors(descriptors: meshDescriptors)
        return try await MeshResource(from: sendableDescriptors.descriptors)
    }

    /// Any array of RealityKit materials derived from data in the submeshes.
    /// Falls back to a white PhysicallyBasedMaterial for submeshes with no material (e.g. STL).
    /// NOTE: This iterates all submeshes without filtering. Use `getModelEntity()` to guarantee
    /// that the material list is exactly 1:1 with the valid descriptors.
    func getMaterials() async -> [any RealityKit.Material] {
        var result = [any RealityKit.Material]()
        for mesh in meshes {
            for submesh in mesh.submeshArray {
                if let material = await submesh.material?.getPbrMaterial() {
                    result.append(material)
                } else {
                    var m = PhysicallyBasedMaterial()
                    m.baseColor = .init(tint: .white)
                    result.append(m)
                }
            }
        }
        return result
    }

    /// Asynchronously obtain a `ModelEntity` based on the mesh resources and materials in this asset.
    ///
    /// Processes every submesh in a single synchronized pass: each (descriptor, material) pair is
    /// built from the same submesh, invalid submeshes are skipped in BOTH arrays, and each
    /// descriptor's `materialIndex` is set to the index of its paired material in the final array.
    /// This prevents index drift between descriptors and materials when some submeshes are skipped.
    func getModelEntity() async throws -> ModelEntity {
        let allMeshes = meshes
        print("[RealityKitFormats] MDLAsset: \(allMeshes.count) mesh(es)")

        var descriptors: [MeshDescriptor] = []
        var materials: [any RealityKit.Material] = []

        for mesh in allMeshes {
            let pairs = mesh.validSubmeshPairs()
            for (var descriptor, mdlMaterial) in pairs {
                // .allFaces assigns every primitive in this descriptor to the material
                // at the given slot in the ModelEntity's materials array.
                descriptor.materials = .allFaces(UInt32(materials.count))
                descriptors.append(descriptor)
                if let mat = await mdlMaterial?.getPbrMaterial() {
                    materials.append(mat)
                } else {
                    var m = PhysicallyBasedMaterial()
                    m.baseColor = .init(tint: .white)
                    materials.append(m)
                }
            }
        }

        print("[RealityKitFormats] MDLAsset: \(descriptors.count) descriptor(s), \(materials.count) material(s)")
        let sendable = UnsafeSendableDescriptors(descriptors: descriptors)
        let meshResource = try await MeshResource(from: sendable.descriptors)
        return ModelEntity(mesh: meshResource, materials: materials)
    }

    /// All `MDLPhysicallyPlausibleLight` objects found at the top level of this asset.
    var physicalLights: [MDLPhysicallyPlausibleLight] {
        objects.compactMap { $0 as? MDLPhysicallyPlausibleLight }
    }

    /// Asynchronously obtain an `Entity` containing the mesh and any lights from this asset.
    /// Returns a container `Entity` with the `ModelEntity` and light children when lights are
    /// present; returns the `ModelEntity` directly (preserving `as? ModelEntity` casts) when none.
    func getEntity() async throws -> Entity {
        let modelEntity = try await getModelEntity()
        let lightEntities = physicalLights.compactMap { makeLightEntity(from: $0) }
        if lightEntities.isEmpty { return modelEntity }
        let container = Entity()
        container.addChild(modelEntity)
        for light in lightEntities { container.addChild(light) }
        return container
    }

    private func makeLightEntity(from light: MDLPhysicallyPlausibleLight) -> Entity? {
        let entity = Entity()
        entity.name = light.name
        if let matrix = light.transform?.matrix {
            entity.transform = Transform(matrix: matrix)
        }
        var rkColor: PointLightComponent.Color = .white
        if let cg = light.color {
            #if os(macOS)
            rkColor = PointLightComponent.Color(cgColor: cg) ?? .white
            #else
            rkColor = PointLightComponent.Color(cgColor: cg)
            #endif
        }
        switch light.lightType {
        case .point:
            entity.components.set(PointLightComponent(color: rkColor, intensity: light.lumens))
        case .directional:
            entity.components.set(DirectionalLightComponent(color: rkColor, intensity: light.lumens))
        case .spot:
            entity.components.set(SpotLightComponent(
                color: rkColor, intensity: light.lumens,
                innerAngleInDegrees: light.innerConeAngle,
                outerAngleInDegrees: light.outerConeAngle
            ))
        default:
            return nil
        }
        return entity
    }

    // TODO: I don't like the wrappers below, but it was a correction for "sending self.materials risks causing data races"

    /// Wrapper to make non-Sendable descriptors transferable across actor boundaries
    private struct UnsafeSendableDescriptors: @unchecked Sendable {
        let descriptors: [MeshDescriptor]
    }
}

