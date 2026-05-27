//
//  Entity+Write.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 5/25/26.
//

import Foundation
import ImageIO
import Metal
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

private enum TextureExportError: Error, LocalizedError {
    case noMetalDevice
    case textureAllocationFailed
    case blitEncoderFailed
    case imageCreationFailed
    case imageSaveFailed(URL)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "No Metal device available for texture export"
        case .textureAllocationFailed: return "Failed to allocate MTLTexture for texture export"
        case .blitEncoderFailed: return "Failed to create blit command encoder for texture synchronization"
        case .imageCreationFailed: return "Failed to create CGImage from texture pixel data"
        case .imageSaveFailed(let url): return "Failed to save texture image at \(url.lastPathComponent)"
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

        let isUSDZ = url.pathExtension.lowercased() == "usdz"

        // For USDZ, create a staging directory so textures land alongside the USDA before packaging
        let stagingDir: URL?
        if isUSDZ {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            stagingDir = dir
        } else {
            stagingDir = nil
        }
        defer { if let dir = stagingDir { try? FileManager.default.removeItem(at: dir) } }

        let asset = MDLAsset()
        let allocator = MDLMeshBufferDataAllocator()
        var materialCounter = 0

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
                    let mdlMaterial = try pbr.map { try makeMDLMaterial(from: $0, textureDir: stagingDir, index: materialCounter) }
                    materialCounter += 1

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

        if isUSDZ {
            let usda = stagingDir!.appendingPathComponent("model.usda")
            try asset.export(to: usda)
            try packageAsUSDZ(stagingDir: stagingDir!, to: url)
        } else {
            try asset.export(to: url)
        }
    }
}

/// Copies a TextureResource to an MTLTexture, reads back the pixels, and writes a PNG to the given directory.
@MainActor
private func writeTextureResource(_ resource: TextureResource, named name: String, in directory: URL) throws -> URL {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw TextureExportError.noMetalDevice
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: resource.width,
        height: resource.height,
        mipmapped: false
    )
    descriptor.usage = .shaderWrite

    guard let mtlTexture = device.makeTexture(descriptor: descriptor) else {
        throw TextureExportError.textureAllocationFailed
    }

    try resource.copy(to: mtlTexture)

    #if os(macOS)
    if mtlTexture.storageMode == .managed {
        guard let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else { throw TextureExportError.blitEncoderFailed }
        blitEncoder.synchronize(resource: mtlTexture)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    #endif

    let bytesPerRow = 4 * resource.width
    var bytes = [UInt8](repeating: 0, count: resource.height * bytesPerRow)
    bytes.withUnsafeMutableBytes { ptr in
        mtlTexture.getBytes(
            ptr.baseAddress!,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: resource.width, height: resource.height, depth: 1)),
            mipmapLevel: 0
        )
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let dataProvider = CGDataProvider(data: Data(bytes) as CFData),
          let cgImage = CGImage(
              width: resource.width,
              height: resource.height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: bytesPerRow,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: dataProvider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          )
    else {
        throw TextureExportError.imageCreationFailed
    }

    let destURL = directory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(destURL as CFURL, "public.png" as CFString, 1, nil) else {
        throw TextureExportError.imageSaveFailed(destURL)
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw TextureExportError.imageSaveFailed(destURL)
    }

    return destURL
}

/// Builds an MDLMaterial from a PhysicallyBasedMaterial.
/// When textureDir is provided, each texture property is written as a PNG and referenced by absolute URL;
/// scalars are used as fallback for properties without textures.
@MainActor
private func makeMDLMaterial(from pbr: PhysicallyBasedMaterial, textureDir: URL?, index: Int) throws -> MDLMaterial {
    let mdl = MDLMaterial(name: "material", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())

    // Base color: texture if available, else solid tint
    if let texDir = textureDir, let texResource = pbr.baseColor.texture?.resource {
        let texURL = try writeTextureResource(texResource, named: "mat\(index)_baseColor.png", in: texDir)
        let prop = MDLMaterialProperty(name: "baseColor", semantic: .baseColor)
        prop.urlValue = texURL
        mdl.setProperty(prop)
    } else {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        #if os(macOS)
        (pbr.baseColor.tint.usingColorSpace(.sRGB) ?? pbr.baseColor.tint).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        pbr.baseColor.tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let colorProp = MDLMaterialProperty(name: "baseColor", semantic: .baseColor)
        colorProp.float4Value = SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
        mdl.setProperty(colorProp)
    }

    // Normal texture
    if let texDir = textureDir, let texResource = pbr.normal.texture?.resource {
        let texURL = try writeTextureResource(texResource, named: "mat\(index)_normal.png", in: texDir)
        let prop = MDLMaterialProperty(name: "normal", semantic: .tangentSpaceNormal)
        prop.urlValue = texURL
        mdl.setProperty(prop)
    }

    // Roughness: texture or scalar
    if let texDir = textureDir, let texResource = pbr.roughness.texture?.resource {
        let texURL = try writeTextureResource(texResource, named: "mat\(index)_roughness.png", in: texDir)
        let prop = MDLMaterialProperty(name: "roughness", semantic: .roughness)
        prop.urlValue = texURL
        mdl.setProperty(prop)
    } else {
        let prop = MDLMaterialProperty(name: "roughness", semantic: .roughness)
        prop.floatValue = pbr.roughness.scale
        mdl.setProperty(prop)
    }

    // Metallic: texture or scalar
    if let texDir = textureDir, let texResource = pbr.metallic.texture?.resource {
        let texURL = try writeTextureResource(texResource, named: "mat\(index)_metallic.png", in: texDir)
        let prop = MDLMaterialProperty(name: "metallic", semantic: .metallic)
        prop.urlValue = texURL
        mdl.setProperty(prop)
    } else {
        let prop = MDLMaterialProperty(name: "metallic", semantic: .metallic)
        prop.floatValue = pbr.metallic.scale
        mdl.setProperty(prop)
    }

    // Emissive texture
    if let texDir = textureDir, let texResource = pbr.emissiveColor.texture?.resource {
        let texURL = try writeTextureResource(texResource, named: "mat\(index)_emissive.png", in: texDir)
        let prop = MDLMaterialProperty(name: "emission", semantic: .emission)
        prop.urlValue = texURL
        mdl.setProperty(prop)
    }

    // Ambient occlusion texture
    if let texDir = textureDir, let texResource = pbr.ambientOcclusion.texture?.resource {
        let texURL = try writeTextureResource(texResource, named: "mat\(index)_ambientOcclusion.png", in: texDir)
        let prop = MDLMaterialProperty(name: "ambientOcclusion", semantic: .ambientOcclusion)
        prop.urlValue = texURL
        mdl.setProperty(prop)
    }

    return mdl
}

/// Post-processes the exported USDA to replace absolute texture paths with bare filenames
/// (USDZ is a flat archive), then bundles all files in stagingDir into a USDZ ZIP.
private func packageAsUSDZ(stagingDir: URL, to url: URL) throws {
    let files = try FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
    guard let usda = files.first(where: { $0.pathExtension == "usda" }) else {
        throw ModelIOWriteError.exportFailed(url)
    }

    // Replace absolute texture paths with bare filenames so references work inside the flat USDZ archive
    var usdaText = try String(contentsOf: usda, encoding: .utf8)
    for file in files where file != usda {
        usdaText = usdaText.replacingOccurrences(of: file.path, with: file.lastPathComponent)
        usdaText = usdaText.replacingOccurrences(of: file.absoluteString, with: file.lastPathComponent)
    }
    try usdaText.write(to: usda, atomically: true, encoding: .utf8)

    // USDA must be the first entry in a valid USDZ archive
    let sortedFiles = files.sorted { a, b in
        if a.pathExtension == "usda" { return true }
        if b.pathExtension == "usda" { return false }
        return a.lastPathComponent < b.lastPathComponent
    }

    var zip = Data()
    var centralDirectory = Data()
    var fileCount: UInt16 = 0

    for fileURL in sortedFiles {
        let fileData = try Data(contentsOf: fileURL)
        let filenameBytes = Data(fileURL.lastPathComponent.utf8)
        let crc = zipCRC32(fileData)
        let size = UInt32(fileData.count)
        let localHeaderOffset = UInt32(zip.count)

        // Local file header
        zip.appendLE(UInt32(0x04034b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(crc); zip.appendLE(size); zip.appendLE(size)
        zip.appendLE(UInt16(filenameBytes.count)); zip.appendLE(UInt16(0))
        zip.append(filenameBytes)
        zip.append(fileData)

        // Central directory entry
        centralDirectory.appendLE(UInt32(0x02014b50)); centralDirectory.appendLE(UInt16(20)); centralDirectory.appendLE(UInt16(20))
        centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0))
        centralDirectory.appendLE(crc); centralDirectory.appendLE(size); centralDirectory.appendLE(size)
        centralDirectory.appendLE(UInt16(filenameBytes.count)); centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0))
        centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt32(0))
        centralDirectory.appendLE(localHeaderOffset)
        centralDirectory.append(filenameBytes)
        fileCount += 1
    }

    let centralDirOffset = UInt32(zip.count)
    let centralDirSize = UInt32(centralDirectory.count)
    zip.append(centralDirectory)

    // End of central directory record
    zip.appendLE(UInt32(0x06054b50)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
    zip.appendLE(fileCount); zip.appendLE(fileCount)
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
