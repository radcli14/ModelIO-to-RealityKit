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
            let materials = modelEntity.model?.materials ?? []
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

                    let materialIndex = Int(part.materialIndex)
                    let pbr = (materialIndex < materials.count ? materials[materialIndex] : materials.first) as? PhysicallyBasedMaterial
                    let mdlMaterial = pbr.map { makeMDLMaterial(from: $0) }

                    let submesh = MDLSubmesh(
                        indexBuffer: indexBuffer,
                        indexCount: indexArray.count,
                        indexType: .uInt32,
                        geometryType: .triangles,
                        material: mdlMaterial
                    )

                    let mdlMesh = MDLMesh(
                        vertexBuffer: vertexBuffer,
                        vertexCount: positions.count,
                        descriptor: vertexDescriptor,
                        submeshes: [submesh]
                    )

                    asset.add(mdlMesh)
                }
            }
        }

        if url.pathExtension.lowercased() == "usdz" {
            try packageAsUSDZ(asset: asset, to: url)
        } else {
            try asset.export(to: url)
        }
    }
}

/// Builds an MDLMaterial from a PhysicallyBasedMaterial's scalar properties.
/// Normal texture export is not yet supported because TextureResource has no direct
/// pixel-extraction path without a full Metal pipeline setup.
private func makeMDLMaterial(from pbr: PhysicallyBasedMaterial) -> MDLMaterial {
    let mdl = MDLMaterial(name: "material", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())

    var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
    #if os(macOS)
    (pbr.baseColor.tint.usingColorSpace(.sRGB) ?? pbr.baseColor.tint).getRed(&r, green: &g, blue: &b, alpha: &a)
    #else
    pbr.baseColor.tint.getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    let colorProp = MDLMaterialProperty(name: "baseColor", semantic: .baseColor)
    colorProp.float4Value = SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    mdl.setProperty(colorProp)

    let roughnessProp = MDLMaterialProperty(name: "roughness", semantic: .roughness)
    roughnessProp.floatValue = pbr.roughness.scale
    mdl.setProperty(roughnessProp)

    let metallicProp = MDLMaterialProperty(name: "metallic", semantic: .metallic)
    metallicProp.floatValue = pbr.metallic.scale
    mdl.setProperty(metallicProp)

    return mdl
}

/// Exports the MDLAsset to a USDA file and packages it as a USDZ ZIP archive.
/// USDZ files are uncompressed (stored) ZIP archives; MDLAsset handles the USD layer export.
private func packageAsUSDZ(asset: MDLAsset, to url: URL) throws {
    let tempUSDA = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("usda")
    defer { try? FileManager.default.removeItem(at: tempUSDA) }

    try asset.export(to: tempUSDA)
    let fileData = try Data(contentsOf: tempUSDA)
    let filenameBytes = Data("model.usda".utf8)

    let crc = zipCRC32(fileData)
    let size = UInt32(fileData.count)
    var zip = Data()

    // Local file header
    let localHeaderOffset = UInt32(0)
    zip.appendLE(UInt32(0x04034b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(0))
    zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
    zip.appendLE(crc); zip.appendLE(size); zip.appendLE(size)
    zip.appendLE(UInt16(filenameBytes.count)); zip.appendLE(UInt16(0))
    zip.append(filenameBytes)
    zip.append(fileData)

    // Central directory entry
    let centralDirOffset = UInt32(zip.count)
    zip.appendLE(UInt32(0x02014b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(20))
    zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
    zip.appendLE(crc); zip.appendLE(size); zip.appendLE(size)
    zip.appendLE(UInt16(filenameBytes.count)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
    zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt32(0))
    zip.appendLE(localHeaderOffset)
    zip.append(filenameBytes)

    let centralDirSize = UInt32(zip.count) - centralDirOffset

    // End of central directory record
    zip.appendLE(UInt32(0x06054b50)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
    zip.appendLE(UInt16(1)); zip.appendLE(UInt16(1))
    zip.appendLE(centralDirSize); zip.appendLE(centralDirOffset); zip.appendLE(UInt16(0))

    try zip.write(to: url)
}

/// CRC-32 using the standard IEEE 802.3 polynomial, required by the ZIP format.
private func zipCRC32(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        table[i] = c
    }
    return data.reduce(UInt32(0xFFFFFFFF)) {
        table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8)
    } ^ 0xFFFFFFFF
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<T>.size))
    }
}
