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

private enum ExportedLight {
    case point(name: String, position: SIMD3<Float>, color: SIMD3<Float>, intensity: Float)
    case directional(name: String, rotation: simd_quatf, color: SIMD3<Float>, intensity: Float)
    case spot(name: String, position: SIMD3<Float>, rotation: simd_quatf, color: SIMD3<Float>, intensity: Float, innerAngle: Float, outerAngle: Float)
}

@MainActor
private func collectLights(_ entity: Entity, counter: inout Int) -> [ExportedLight] {
    var result = [ExportedLight]()
    let rawName = entity.name.isEmpty ? "light" : entity.name
    let safe = rawName.filter { $0.isLetter || $0.isNumber || $0 == "_" }
    let safeName = safe.isEmpty ? "light" : safe
    let pos = entity.position(relativeTo: nil)
    let rot = Transform(matrix: entity.transformMatrix(relativeTo: nil)).rotation

    func extractRGB(from color: PointLightComponent.Color) -> SIMD3<Float> {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1
        #if os(macOS)
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: nil)
        #else
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        #endif
        return SIMD3<Float>(Float(r), Float(g), Float(b))
    }

    if let comp = entity.components[PointLightComponent.self] {
        result.append(.point(name: "\(safeName)_\(counter)", position: pos, color: extractRGB(from: comp.color), intensity: comp.intensity))
        counter += 1
    }
    if let comp = entity.components[DirectionalLightComponent.self] {
        result.append(.directional(name: "\(safeName)_\(counter)", rotation: rot, color: extractRGB(from: comp.color), intensity: comp.intensity))
        counter += 1
    }
    if let comp = entity.components[SpotLightComponent.self] {
        result.append(.spot(name: "\(safeName)_\(counter)", position: pos, rotation: rot, color: extractRGB(from: comp.color), intensity: comp.intensity, innerAngle: comp.innerAngleInDegrees, outerAngle: comp.outerAngleInDegrees))
        counter += 1
    }
    for child in entity.children {
        result.append(contentsOf: collectLights(child, counter: &counter))
    }
    return result
}

private func generateLightPrims(_ lights: [ExportedLight]) -> String {
    var lines = [String]()
    for light in lights {
        switch light {
        case .point(let name, let pos, let col, let intensity):
            lines += [
                "",
                "    def SphereLight \"\(name)\"",
                "    {",
                "        float inputs:intensity = \(intensity)",
                "        color3f inputs:color = (\(col.x), \(col.y), \(col.z))",
                "        float inputs:radius = 0",
                "        bool treatAsPoint = 1",
                "        double3 xformOp:translate = (\(Double(pos.x)), \(Double(pos.y)), \(Double(pos.z)))",
                "        uniform token[] xformOpOrder = [\"xformOp:translate\"]",
                "    }",
            ]
        case .directional(let name, let rot, let col, let intensity):
            lines += [
                "",
                "    def DistantLight \"\(name)\"",
                "    {",
                "        float inputs:intensity = \(intensity)",
                "        color3f inputs:color = (\(col.x), \(col.y), \(col.z))",
                "        quatf xformOp:orient = (\(rot.real), \(rot.imag.x), \(rot.imag.y), \(rot.imag.z))",
                "        uniform token[] xformOpOrder = [\"xformOp:orient\"]",
                "    }",
            ]
        case .spot(let name, let pos, let rot, let col, let intensity, let inner, let outer):
            let softness = outer > 0 ? (outer - inner) / outer : 0
            lines += [
                "",
                "    def SphereLight \"\(name)\" (",
                "        prepend apiSchemas = [\"ShapingAPI\"]",
                "    )",
                "    {",
                "        float inputs:intensity = \(intensity)",
                "        color3f inputs:color = (\(col.x), \(col.y), \(col.z))",
                "        float inputs:shaping:cone:angle = \(outer)",
                "        float inputs:shaping:cone:softness = \(softness)",
                "        float inputs:radius = 0",
                "        bool treatAsPoint = 1",
                "        double3 xformOp:translate = (\(Double(pos.x)), \(Double(pos.y)), \(Double(pos.z)))",
                "        quatf xformOp:orient = (\(rot.real), \(rot.imag.x), \(rot.imag.y), \(rot.imag.z))",
                "        uniform token[] xformOpOrder = [\"xformOp:translate\", \"xformOp:orient\"]",
                "    }",
            ]
        }
    }
    return lines.joined(separator: "\n")
}

private func injectLights(_ lights: [ExportedLight], into text: inout String) {
    guard !lights.isEmpty, let lastBrace = text.lastIndex(of: "}") else { return }
    text.insert(contentsOf: generateLightPrims(lights) + "\n", at: lastBrace)
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
        case .textureAllocationFailed: return "Failed to allocate MTLTexture"
        case .blitEncoderFailed: return "Failed to create blit encoder for managed texture sync"
        case .imageCreationFailed: return "Failed to create CGImage from texture pixels"
        case .imageSaveFailed(let url): return "Failed to save PNG at \(url.lastPathComponent)"
        }
    }
}

// Carries all per-material data needed for both MDLSubmesh creation and USDA patching.
// MDLAsset.export silently drops urlValue on MDLMaterialProperty, so texture references
// are injected into the USDA after export via patchMaterialsSection.
private struct MaterialRecord {
    let mdlMaterial: MDLMaterial   // placeholder used only for material binding in USD
    let name: String               // USD prim name: "mat0", "mat1", …
    let roughnessScale: Float
    let metallicScale: Float
    let baseColorTint: SIMD4<Float>
    let emissiveColorTint: SIMD3<Float>
    let opacity: Float
    // USD input key → bare PNG filename (e.g. "diffuseColor" → "mat0_baseColor.png")
    let textureFiles: [String: String]
    var hasTextures: Bool { !textureFiles.isEmpty }
}

/// All skeleton/animation data needed to write USD SkelRoot / Skeleton / SkelAnimation prims.
private struct SkelExportData {
    let skeleton: MeshResource.Skeleton
    let jointPaths: [String]        // USD slash-separated path per joint: "Palm", "Palm/Thumb0", …
    let poseTransforms: [Transform] // current-pose transforms, local (parent-relative) space
}

/// Joint influence data for one mesh part, indexed by its insertion order into MDLAsset.
private struct PartInfluenceRecord {
    let meshIndex: Int                          // 0-based; matches prim names found in the USDA
    let influences: MeshResource.JointInfluences
    let influencesPerVertex: Int                // influences.count / vertexCount; computed at collection time
}

@MainActor public extension Entity {

    func writeMDLAsset(to url: URL) async throws {
        let modelEntities = collectModelEntities(self)
        guard !modelEntities.isEmpty else { throw ModelIOWriteError.noMeshesFound }

        let isUSDZ = url.pathExtension.lowercased() == "usdz"
        let isOBJ = url.pathExtension.lowercased() == "obj"

        // Staging directory lets texture PNGs land alongside the USDA before USDZ packaging
        let stagingDir: URL?
        if isUSDZ {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            stagingDir = dir
        } else {
            stagingDir = nil
        }
        // For OBJ exports, textures land in the same directory as the .obj file so MDLAsset
        // can reference them by relative path in the generated .mtl file
        let objTextureDir: URL? = isOBJ ? url.deletingLastPathComponent() : nil
        defer { if let d = stagingDir { try? FileManager.default.removeItem(at: d) } }

        let asset = MDLAsset()
        let allocator = MDLMeshBufferDataAllocator()
        var materialRecords = [MaterialRecord]()
        var materialCounter = 0

        // Skeleton and per-part influence data collected during the mesh loop below.
        var skelData: SkelExportData?
        var partInfluences = [PartInfluenceRecord]()
        var meshIndex = 0

        for modelEntity in modelEntities {
            guard let models = modelEntity.model?.mesh.contents.models else { continue }
            let materials = modelEntity.model?.materials ?? []
            let worldTransform = modelEntity.transformMatrix(relativeTo: nil)
            let normalMatrix = simd_float3x3(columns: (
                SIMD3<Float>(worldTransform[0].x, worldTransform[0].y, worldTransform[0].z),
                SIMD3<Float>(worldTransform[1].x, worldTransform[1].y, worldTransform[1].z),
                SIMD3<Float>(worldTransform[2].x, worldTransform[2].y, worldTransform[2].z)
            ))

            // Collect the first skeleton found in this entity's mesh resource.
            if skelData == nil, let mesh = modelEntity.model?.mesh,
               let skel = mesh.contents.skeletons.first(where: { _ in true }) {
                // jointNames on ModelEntity returns the USD joint path tokens in the same order
                // as the skeleton joints and joint influences — use them directly when available.
                let rawNames = modelEntity.jointNames
                let paths = rawNames.isEmpty ? buildJointPaths(from: skel) : rawNames
                let rawPose = modelEntity.jointTransforms
                // Prefer live joint transforms; fall back to rest-pose transforms if unavailable.
                let pose = rawPose.isEmpty ? skel.joints.map { $0.restPoseTransform } : rawPose
                skelData = SkelExportData(skeleton: skel, jointPaths: paths, poseTransforms: pose)
            }

            for model in models {
                for part in model.parts {
                    let positions = part.positions.elements
                    guard !positions.isEmpty else { continue }
                    let normals = part.normals?.elements
                    let uvs = part.textureCoordinates?.elements
                    guard let triangleIndicesBuffer = part.triangleIndices else { continue }
                    let indexArray = triangleIndicesBuffer.elements

                    // Transform positions to world space up front — used for both the vertex
                    // buffer and face-normal computation when the source mesh has none.
                    let worldPositions = positions.map { p -> SIMD3<Float> in
                        let pw = worldTransform * SIMD4<Float>(p.x, p.y, p.z, 1)
                        return SIMD3<Float>(pw.x, pw.y, pw.z)
                    }

                    // Skinned mesh parts must export bind-pose positions; the USD skeleton handles
                    // the deformation. Static mesh parts bake the world transform into vertices.
                    let hasSkinning = part.jointInfluences != nil
                    let exportPositions = hasSkinning ? positions : worldPositions

                    // Always write per-vertex normals. If the source has none (e.g. generated
                    // primitives, STL), compute flat face normals from triangle connectivity.
                    // addNormals(withAttributeNamed:) fails silently with MDLMeshBufferDataAllocator.
                    let hasNormals = normals?.count == positions.count
                    let hasUVs = uvs?.count == positions.count
                    let effectiveNormals: [SIMD3<Float>]
                    if hasNormals {
                        // Skinned normals remain in bind-pose space; the skeleton deforms them.
                        effectiveNormals = hasSkinning
                            ? normals!
                            : normals!.map { normalize(normalMatrix * $0) }
                    } else {
                        var computed = [SIMD3<Float>](repeating: .zero, count: positions.count)
                        stride(from: 0, to: indexArray.count - 2, by: 3).forEach { t in
                            let i0 = Int(indexArray[t]), i1 = Int(indexArray[t+1]), i2 = Int(indexArray[t+2])
                            guard i0 < exportPositions.count, i1 < exportPositions.count, i2 < exportPositions.count else { return }
                            let fn = normalize(cross(exportPositions[i1] - exportPositions[i0],
                                                     exportPositions[i2] - exportPositions[i0]))
                            computed[i0] = fn; computed[i1] = fn; computed[i2] = fn
                        }
                        effectiveNormals = computed
                    }

                    // Interleaved layout: float3 position (12) + float3 normal (12) + optional float2 uv (8)
                    var attrList = [MDLVertexAttribute]()
                    let posAttr = MDLVertexAttribute()
                    posAttr.name = MDLVertexAttributePosition; posAttr.format = .float3
                    posAttr.offset = 0; posAttr.bufferIndex = 0
                    attrList.append(posAttr)
                    let normAttr = MDLVertexAttribute()
                    normAttr.name = MDLVertexAttributeNormal; normAttr.format = .float3
                    normAttr.offset = 12; normAttr.bufferIndex = 0
                    attrList.append(normAttr)
                    if hasUVs {
                        let uvAttr = MDLVertexAttribute()
                        uvAttr.name = MDLVertexAttributeTextureCoordinate; uvAttr.format = .float2
                        uvAttr.offset = 24; uvAttr.bufferIndex = 0
                        attrList.append(uvAttr)
                    }
                    let stride = hasUVs ? 32 : 24
                    let vertexDescriptor = MDLVertexDescriptor()
                    vertexDescriptor.attributes = NSMutableArray(array: attrList)
                    let layout = MDLVertexBufferLayout(); layout.stride = stride
                    vertexDescriptor.layouts = NSMutableArray(array: [layout])

                    var vertexData = Data()
                    vertexData.reserveCapacity(positions.count * stride)
                    for i in 0..<positions.count {
                        var xyz = (exportPositions[i].x, exportPositions[i].y, exportPositions[i].z)
                        withUnsafeBytes(of: &xyz) { vertexData.append(contentsOf: $0) }
                        var nxyz = (effectiveNormals[i].x, effectiveNormals[i].y, effectiveNormals[i].z)
                        withUnsafeBytes(of: &nxyz) { vertexData.append(contentsOf: $0) }
                        if hasUVs {
                            let uv = uvs![i]
                            var uvxy = (uv.x, uv.y)
                            withUnsafeBytes(of: &uvxy) { vertexData.append(contentsOf: $0) }
                        }
                    }

                    let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
                    let indexData = indexArray.withUnsafeBytes { Data($0) }
                    let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

                    let matIdx = Int(part.materialIndex)
                    let pbr = (matIdx < materials.count ? materials[matIdx] : materials.first) as? PhysicallyBasedMaterial
                    let record = try pbr.map { try makeMatRecord(from: $0, textureDir: stagingDir ?? objTextureDir, index: materialCounter) }
                    materialCounter += 1
                    if let r = record { materialRecords.append(r) }

                    let submesh = MDLSubmesh(
                        indexBuffer: indexBuffer,
                        indexCount: indexArray.count,
                        indexType: .uInt32,
                        geometryType: .triangles,
                        material: record?.mdlMaterial
                    )
                    let mdlMesh = MDLMesh(
                        vertexBuffer: vertexBuffer,
                        vertexCount: positions.count,
                        descriptor: vertexDescriptor,
                        submeshes: [submesh]
                    )
                    asset.add(mdlMesh)

                    if hasSkinning, let inf = part.jointInfluences {
                        let ipv = positions.isEmpty ? 0 : inf.influences.count / positions.count
                        partInfluences.append(PartInfluenceRecord(meshIndex: meshIndex, influences: inf,
                                                                   influencesPerVertex: ipv))
                    }
                    meshIndex += 1
                }
            }
        }

        // Collect lights from the entity tree for injection into USD text formats.
        var lightCounter = 0
        let exportedLights = collectLights(self, counter: &lightCounter)

        if isUSDZ {
            let usda = stagingDir!.appendingPathComponent("model.usda")
            try asset.export(to: usda)
            // USD's implicit default for metersPerUnit is 0.01 (centimeters). MDLAsset doesn't
            // write the key at all, so RealityKit falls back to 0.01 and multiplies every vertex
            // coordinate by that factor on load — making the model 100× too small.
            // Fix: correct any explicit 0.01 value written by some MDLAsset versions, then
            // insert metersPerUnit = 1 into the layer header if none was written.
            var usdaText = try String(contentsOf: usda, encoding: .utf8)
            usdaText = usdaText
                .replacingOccurrences(of: "double metersPerUnit = 0.01", with: "double metersPerUnit = 1")
                .replacingOccurrences(of: "metersPerUnit = 0.01",        with: "metersPerUnit = 1")
            if !usdaText.contains("metersPerUnit") {
                usdaText = usdaText.replacingOccurrences(
                    of: "\n)\n\ndef Xform",
                    with: "\n    metersPerUnit = 1\n)\n\ndef Xform"
                )
            }
            injectLights(exportedLights, into: &usdaText)
            // Inject USD skeleton prims when the source has skinned mesh data.
            if let skel = skelData, !partInfluences.isEmpty {
                var rootPrim = "model"
                if let r = usdaText.range(of: "defaultPrim = \"") {
                    let after = usdaText[r.upperBound...]
                    if let end = after.firstIndex(of: "\"") { rootPrim = String(after[..<end]) }
                }
                // Work on a copy; only commit if the root prim was actually found and modified.
                var candidate = usdaText
                injectSkelPrims(into: &candidate, rootPrim: rootPrim, skelData: skel,
                                partInfluences: partInfluences)
                // Confirm the injection produced a SkelRoot prim before committing.
                if candidate.contains("def SkelRoot") {
                    usdaText = candidate
                }
            }
            try usdaText.write(to: usda, atomically: true, encoding: .utf8)
            // MDLAsset.export drops urlValue on MDLMaterialProperty, so texture UsdUVTexture nodes
            // must be injected by replacing the Materials scope after the fact.
            if materialRecords.contains(where: \.hasTextures) {
                try patchMaterialsSection(in: usda, records: materialRecords)
            }
            try packageAsUSDZ(stagingDir: stagingDir!, to: url)
        } else if isOBJ {
            try asset.export(to: url)
        } else {
            try asset.export(to: url)
            // For USDA, inject lights into the exported text file.
            if url.pathExtension.lowercased() == "usda" && !exportedLights.isEmpty {
                var usdat = try String(contentsOf: url, encoding: .utf8)
                injectLights(exportedLights, into: &usdat)
                try usdat.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

@MainActor
private func collectModelEntities(_ entity: Entity) -> [ModelEntity] {
    var result = [ModelEntity]()
    if let me = entity as? ModelEntity { result.append(me) }
    for child in entity.children { result.append(contentsOf: collectModelEntities(child)) }
    return result
}

/// Copies a TextureResource to an MTLTexture, reads pixel bytes, and writes a PNG to the directory.
@MainActor
private func writeTextureResource(_ resource: TextureResource, named name: String, in directory: URL) throws -> URL {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw TextureExportError.noMetalDevice
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: resource.width, height: resource.height, mipmapped: false)
    descriptor.usage = .shaderWrite
    // .shared storage mode ensures CPU readback via getBytes always works.
    // Without this, the default mode on macOS may be .private, silently returning zeros.
    descriptor.storageMode = .shared
    guard let mtlTexture = device.makeTexture(descriptor: descriptor) else {
        throw TextureExportError.textureAllocationFailed
    }
    try resource.copy(to: mtlTexture)
    #if os(macOS)
    if mtlTexture.storageMode == .managed {
        guard let queue = device.makeCommandQueue(),
              let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder()
        else { throw TextureExportError.blitEncoderFailed }
        blit.synchronize(resource: mtlTexture)
        blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
    }
    #endif
    let bytesPerRow = 4 * resource.width
    var bytes = [UInt8](repeating: 0, count: resource.height * bytesPerRow)
    bytes.withUnsafeMutableBytes { ptr in
        mtlTexture.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: resource.width, height: resource.height, depth: 1)),
            mipmapLevel: 0)
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let dataProvider = CGDataProvider(data: Data(bytes) as CFData),
          let cgImage = CGImage(
              width: resource.width, height: resource.height,
              bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw TextureExportError.imageCreationFailed }

    let destURL = directory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(destURL as CFURL, "public.png" as CFString, 1, nil) else {
        throw TextureExportError.imageSaveFailed(destURL)
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { throw TextureExportError.imageSaveFailed(destURL) }
    return destURL
}

/// Builds a MaterialRecord: an MDLMaterial placeholder for mesh binding plus scalar/texture metadata
/// used later to generate correct USD material nodes in patchMaterialsSection.
@MainActor
private func makeMatRecord(from pbr: PhysicallyBasedMaterial, textureDir: URL?, index: Int) throws -> MaterialRecord {
    let name = "mat\(index)"
    let mdl = MDLMaterial(name: name, scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())

    var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
    #if os(macOS)
    (pbr.baseColor.tint.usingColorSpace(.sRGB) ?? pbr.baseColor.tint).getRed(&r, green: &g, blue: &b, alpha: &a)
    #else
    pbr.baseColor.tint.getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    let colorProp = MDLMaterialProperty(name: "baseColor", semantic: .baseColor)
    colorProp.float4Value = SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    mdl.setProperty(colorProp)
    let roughProp = MDLMaterialProperty(name: "roughness", semantic: .roughness)
    roughProp.floatValue = pbr.roughness.scale; mdl.setProperty(roughProp)
    let metalProp = MDLMaterialProperty(name: "metallic", semantic: .metallic)
    metalProp.floatValue = pbr.metallic.scale; mdl.setProperty(metalProp)

    var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0
    #if os(macOS)
    (pbr.emissiveColor.color.usingColorSpace(.sRGB) ?? pbr.emissiveColor.color).getRed(&er, green: &eg, blue: &eb, alpha: nil)
    #else
    pbr.emissiveColor.color.getRed(&er, green: &eg, blue: &eb, alpha: nil)
    #endif
    let emissiveProp = MDLMaterialProperty(name: "emissiveColor", semantic: .emission)
    emissiveProp.float4Value = SIMD4<Float>(Float(er), Float(eg), Float(eb), 1)
    mdl.setProperty(emissiveProp)

    var opacity: Float = 1.0
    if case .transparent(let o) = pbr.blending { opacity = o.scale }
    let opacityProp = MDLMaterialProperty(name: "opacity", semantic: .opacity)
    opacityProp.floatValue = opacity
    mdl.setProperty(opacityProp)

    var textureFiles = [String: String]()
    if let dir = textureDir {
        let slots: [(resource: TextureResource?, key: String, filename: String, mdlSemantic: MDLMaterialSemantic)] = [
            (pbr.baseColor.texture?.resource,       "diffuseColor",  "\(name)_baseColor.png",       .baseColor),
            (pbr.normal.texture?.resource,          "normal",        "\(name)_normal.png",          .tangentSpaceNormal),
            (pbr.roughness.texture?.resource,       "roughness",     "\(name)_roughness.png",       .roughness),
            (pbr.metallic.texture?.resource,        "metallic",      "\(name)_metallic.png",        .metallic),
            (pbr.emissiveColor.texture?.resource,   "emissiveColor", "\(name)_emissive.png",        .emission),
            (pbr.ambientOcclusion.texture?.resource,"occlusion",     "\(name)_ambientOcclusion.png",.ambientOcclusion),
        ]
        for slot in slots {
            guard let res = slot.resource else { continue }
            let fileURL = try writeTextureResource(res, named: slot.filename, in: dir)
            textureFiles[slot.key] = fileURL.lastPathComponent
            let texProp = MDLMaterialProperty(name: slot.key, semantic: slot.mdlSemantic)
            texProp.urlValue = fileURL
            mdl.setProperty(texProp)
        }
    }

    return MaterialRecord(
        mdlMaterial: mdl, name: name,
        roughnessScale: pbr.roughness.scale, metallicScale: pbr.metallic.scale,
        baseColorTint: SIMD4<Float>(Float(r), Float(g), Float(b), Float(a)),
        emissiveColorTint: SIMD3<Float>(Float(er), Float(eg), Float(eb)),
        opacity: opacity,
        textureFiles: textureFiles
    )
}

/// Replaces the `def Scope "Materials"` block in the USDA with a hand-authored version that
/// includes proper UsdPreviewSurface + UsdUVTexture nodes for each material's textures.
/// MDLAsset exports UsdPreviewSurface but silently drops texture URL properties, so we inject
/// them after the fact.
private func patchMaterialsSection(in usda: URL, records: [MaterialRecord]) throws {
    var text = try String(contentsOf: usda, encoding: .utf8)

    var rootPrim = "model"
    if let r = text.range(of: "defaultPrim = \"") {
        let after = text[r.upperBound...]
        if let end = after.firstIndex(of: "\"") { rootPrim = String(after[..<end]) }
    }

    guard let scopeRange = findScopeRange(in: text, named: "Materials") else { return }
    text.replaceSubrange(scopeRange, with: generateMaterialsSection(records, rootPrim: rootPrim))
    try text.write(to: usda, atomically: true, encoding: .utf8)
}

/// Returns the range in `text` covering `def Scope "name" { … }` including any leading indentation.
private func findScopeRange(in text: String, named name: String) -> Range<String.Index>? {
    let marker = "def Scope \"\(name)\""
    guard let keyStart = text.range(of: marker)?.lowerBound else { return nil }

    // Walk back to include leading whitespace on the same line
    var lineStart = keyStart
    while lineStart > text.startIndex {
        let prev = text.index(before: lineStart)
        let c = text[prev]; if c == " " || c == "\t" { lineStart = prev } else { break }
    }

    // Brace-balance walk starting from the opening {
    guard let openBrace = text[keyStart...].firstIndex(of: "{") else { return nil }
    var pos = text.index(after: openBrace)
    var depth = 1
    while pos < text.endIndex, depth > 0 {
        switch text[pos] {
        case "{": depth += 1; pos = text.index(after: pos)
        case "}": depth -= 1; if depth > 0 { pos = text.index(after: pos) }
        default:  pos = text.index(after: pos)
        }
    }
    // pos is at closing }; advance past it and an optional trailing newline
    var endPos = text.index(after: pos)
    if endPos < text.endIndex && text[endPos] == "\n" { endPos = text.index(after: endPos) }
    return lineStart ..< endPos
}

/// Generates a replacement `def Scope "Materials"` block with correct UsdPreviewSurface
/// shader nodes and UsdUVTexture references for any textured properties.
private func generateMaterialsSection(_ records: [MaterialRecord], rootPrim: String) -> String {
    let ind1 = "    "    // 4 sp  — scope level
    let ind2 = "        "    // 8 sp  — material level
    let ind3 = "            "    // 12 sp — shader level
    let ind4 = "                "    // 16 sp — property level

    var lines = ["\(ind1)def Scope \"Materials\"", "\(ind1){"]

    for rec in records {
        let mp = "/\(rootPrim)/Materials/\(rec.name)"

        lines += [
            "\(ind2)def Material \"\(rec.name)\"",
            "\(ind2){",
            "\(ind3)token outputs:surface.connect = <\(mp)/surfaceShader.outputs:surface>",
            "",
            "\(ind3)def Shader \"surfaceShader\"",
            "\(ind3){",
            "\(ind4)uniform token info:id = \"UsdPreviewSurface\"",
            "\(ind4)float inputs:clearcoat = 0",
        ]

        if rec.textureFiles["diffuseColor"] != nil {
            lines.append("\(ind4)color3f inputs:diffuseColor.connect = <\(mp)/baseColorTex.outputs:rgb>")
        } else {
            let c = rec.baseColorTint
            lines.append("\(ind4)color3f inputs:diffuseColor = (\(c.x), \(c.y), \(c.z))")
        }
        if rec.textureFiles["emissiveColor"] != nil {
            lines.append("\(ind4)color3f inputs:emissiveColor.connect = <\(mp)/emissiveTex.outputs:rgb>")
        } else {
            let e = rec.emissiveColorTint
            lines.append("\(ind4)color3f inputs:emissiveColor = (\(e.x), \(e.y), \(e.z))")
        }
        if rec.textureFiles["metallic"] != nil {
            lines.append("\(ind4)float inputs:metallic.connect = <\(mp)/metallicTex.outputs:r>")
        } else {
            lines.append("\(ind4)float inputs:metallic = \(rec.metallicScale)")
        }
        if rec.textureFiles["normal"] != nil {
            lines.append("\(ind4)normal3f inputs:normal.connect = <\(mp)/normalTex.outputs:rgb>")
        }
        if rec.textureFiles["occlusion"] != nil {
            lines.append("\(ind4)float inputs:occlusion.connect = <\(mp)/occlusionTex.outputs:r>")
        }
        if rec.textureFiles["roughness"] != nil {
            lines.append("\(ind4)float inputs:roughness.connect = <\(mp)/roughnessTex.outputs:r>")
        } else {
            lines.append("\(ind4)float inputs:roughness = \(rec.roughnessScale)")
        }
        if rec.opacity < 1.0 {
            lines.append("\(ind4)float inputs:opacity = \(rec.opacity)")
        }
        lines += ["\(ind4)token outputs:surface", "\(ind3)}"]

        if rec.hasTextures {
            lines += [
                "",
                "\(ind3)def Shader \"stReader\"",
                "\(ind3){",
                "\(ind4)uniform token info:id = \"UsdPrimvarReader_float2\"",
                "\(ind4)token inputs:varname = \"st\"",
                "\(ind4)float2 outputs:result",
                "\(ind3)}",
            ]
            // Output types must match USD spec: float for scalars, float3/color3f for vectors.
            // Using "token" here causes RealityKit to discard the connection and fall back to
            // scalar defaults (roughness=0.5, metallic=0, etc.), breaking PBR rendering.
            let slots: [(key: String, shaderName: String, output: String)] = [
                ("diffuseColor",  "baseColorTex", "color3f outputs:rgb"),
                ("normal",        "normalTex",    "float3 outputs:rgb"),
                ("roughness",     "roughnessTex", "float outputs:r"),
                ("metallic",      "metallicTex",  "float outputs:r"),
                ("emissiveColor", "emissiveTex",  "color3f outputs:rgb"),
                ("occlusion",     "occlusionTex", "float outputs:r"),
            ]
            for (key, shaderName, output) in slots {
                guard let filename = rec.textureFiles[key] else { continue }
                lines += [
                    "",
                    "\(ind3)def Shader \"\(shaderName)\"",
                    "\(ind3){",
                    "\(ind4)uniform token info:id = \"UsdUVTexture\"",
                    "\(ind4)asset inputs:file = @\(filename)@",
                    "\(ind4)float2 inputs:st.connect = <\(mp)/stReader.outputs:result>",
                    "\(ind4)\(output)",
                    "\(ind3)}",
                ]
            }
        }

        lines += ["\(ind2)}", ""]
    }

    lines.append("\(ind1)}")
    return lines.joined(separator: "\n") + "\n"
}

// MARK: - USD Skeleton helpers

/// Builds USD joint path strings (e.g. "Palm", "Palm/Thumb0") from parent-index topology.
private func buildJointPaths(from skeleton: MeshResource.Skeleton) -> [String] {
    var paths = [String](repeating: "", count: skeleton.joints.count)
    for (i, joint) in skeleton.joints.enumerated() {
        if let p = joint.parentIndex, p < i {
            paths[i] = paths[p] + "/" + joint.name
        } else {
            paths[i] = joint.name
        }
    }
    return paths
}

/// Returns true when every element of m is a finite float (not nan/inf).
/// USD text parsers reject nan/inf literals and produce .importFailureWithURL on load.
private func isFiniteMatrix(_ m: simd_float4x4) -> Bool {
    let cols = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
    return cols.allSatisfy { c in c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite }
}

/// Formats a simd_float4x4 as a USD `matrix4d` literal in row-major order.
private func matrix4dString(_ m: simd_float4x4) -> String {
    let c = m.columns
    // USD matrix4d rows: row[i] = (col0[i], col1[i], col2[i], col3[i])
    return "((\(c.0.x), \(c.1.x), \(c.2.x), \(c.3.x)), " +
           "(\(c.0.y), \(c.1.y), \(c.2.y), \(c.3.y)), " +
           "(\(c.0.z), \(c.1.z), \(c.2.z), \(c.3.z)), " +
           "(\(c.0.w), \(c.1.w), \(c.2.w), \(c.3.w)))"
}

/// Returns all `def Mesh "…"` prim names found in the USDA text, in document order.
private func findMeshPrimNames(in text: String) -> [String] {
    var names = [String]()
    var cursor = text.startIndex
    while cursor < text.endIndex {
        guard let found = text.range(of: "def Mesh \"", range: cursor..<text.endIndex) else { break }
        let nameStart = found.upperBound
        guard let nameEnd = text[nameStart...].firstIndex(of: "\"") else { break }
        names.append(String(text[nameStart..<nameEnd]))
        cursor = text.index(after: nameEnd)
    }
    return names
}

/// Returns the index of the prim body opening `{`, correctly skipping any metadata `(…)`
/// block that may appear between the prim declaration and its body. USD metadata blocks
/// can contain dictionary values like `assetInfo = { … }` whose inner braces would
/// otherwise be mistaken for the prim body by a naive `firstIndex(of: "{")` search.
private func findPrimBodyBrace(in text: String, from start: String.Index) -> String.Index? {
    var pos = start
    while pos < text.endIndex {
        switch text[pos] {
        case "(":
            // Skip the entire (...) metadata block, including nested parens.
            var depth = 1
            pos = text.index(after: pos)
            while pos < text.endIndex, depth > 0 {
                switch text[pos] {
                case "(": depth += 1; pos = text.index(after: pos)
                case ")": depth -= 1; if depth > 0 { pos = text.index(after: pos) }
                default: pos = text.index(after: pos)
                }
            }
            if pos < text.endIndex { pos = text.index(after: pos) }
        case "{":
            return pos   // first { after any metadata block is the prim body
        default:
            pos = text.index(after: pos)
        }
    }
    return nil
}

/// Inserts `content` just before the closing brace of the first prim named `primName`.
private func insertBeforeClosingBrace(ofPrimNamed primName: String, in text: inout String, content: String) {
    // Search for any prim-type declaration with this name (SkelRoot, Xform, Scope, …).
    let candidates = ["def SkelRoot \"\(primName)\"", "def Xform \"\(primName)\"",
                      "def Scope \"\(primName)\"",    "def \"\(primName)\""]
    var afterMarker: String.Index?
    for candidate in candidates {
        if let r = text.range(of: candidate) { afterMarker = r.upperBound; break }
    }
    guard let start = afterMarker else { return }
    // Use findPrimBodyBrace to skip any (…) metadata block before the prim body {
    guard let openBrace = findPrimBodyBrace(in: text, from: start) else { return }
    var pos = text.index(after: openBrace)
    var depth = 1
    while pos < text.endIndex, depth > 0 {
        switch text[pos] {
        case "{": depth += 1; pos = text.index(after: pos)
        case "}": depth -= 1; if depth > 0 { pos = text.index(after: pos) }
        default:  pos = text.index(after: pos)
        }
    }
    text.insert(contentsOf: content, at: pos)
}

/// Injects USD SkelRoot type change, Skeleton prim, SkelAnimation prim, and per-mesh
/// SkelBindingAPI + joint indices/weights primvars into the exported USDA text.
private func injectSkelPrims(
    into text: inout String,
    rootPrim: String,
    skelData: SkelExportData,
    partInfluences: [PartInfluenceRecord]
) {
    let ind1 = "    "
    let ind2 = "        "

    // 1. Build Skeleton prim content up front — guard before touching the text so a failed
    //    guard leaves the file completely unmodified (avoids a half-injected SkelRoot).
    let jointTokens = skelData.jointPaths.map { "\"\($0)\"" }.joined(separator: ", ")
    // inverseBindPoseMatrix stores M^-1; we need M = (M^-1)^-1 for USD bindTransforms.
    // Guard: simd_float4x4.inverse produces nan/inf for degenerate matrices.
    // USD text parsers reject these literals and return .importFailureWithURL on load.
    let bindMatrices = skelData.skeleton.joints.map { $0.inverseBindPoseMatrix.inverse }
    guard bindMatrices.allSatisfy(isFiniteMatrix) else { return }
    let bindMats = bindMatrices.map { matrix4dString($0) }.joined(separator: ",\n\(ind2)    ")
    // Use the captured live pose transforms as USD restTransforms (the default rendered pose).
    // poseTransforms comes from modelEntity.jointTransforms (local-to-parent) and is always finite.
    let restMats = skelData.poseTransforms.map { matrix4dString($0.matrix) }
        .joined(separator: ",\n\(ind2)    ")

    // SkelRoot is just a scope boundary — it does NOT need SkelBindingAPI.
    // The binding lives on each skinnable mesh prim via SkelBindingAPI + rel skel:skeleton.
    let skelPrimText = "\n" +
        "\(ind1)def Skeleton \"skeleton\"\n" +
        "\(ind1){\n" +
        "\(ind2)uniform token[] joints = [\(jointTokens)]\n" +
        "\(ind2)uniform matrix4d[] bindTransforms = [\(bindMats)]\n" +
        "\(ind2)uniform matrix4d[] restTransforms = [\(restMats)]\n" +
        "\(ind1)}\n"

    // 2. Promote root prim from plain Xform to SkelRoot.
    text = text.replacingOccurrences(of: "def Xform \"\(rootPrim)\"",
                                     with: "def SkelRoot \"\(rootPrim)\"")

    // 3. Insert Skeleton prim inside the root prim body.
    insertBeforeClosingBrace(ofPrimNamed: rootPrim, in: &text, content: skelPrimText)

    // 4. Inject SkelBindingAPI + rel skel:skeleton + skinning primvars into each mesh prim.
    //    Process in REVERSE document order so earlier insertions don't invalidate later indices.
    let meshNames = findMeshPrimNames(in: text)
    for record in partInfluences.reversed() {
        guard record.meshIndex < meshNames.count else { continue }
        let meshName = meshNames[record.meshIndex]
        injectSkinningIntoPrim(named: meshName, rootPrim: rootPrim, in: &text,
                               influences: record.influences,
                               influencesPerVertex: record.influencesPerVertex)
    }
}

/// Injects `SkelBindingAPI`, `rel skel:skeleton`, `primvars:skel:jointIndices`, and
/// `primvars:skel:jointWeights` into a Mesh prim. Each skinnable mesh must carry the
/// `SkelBindingAPI` schema and the `skel:skeleton` relationship directly; RealityKit does not
/// resolve inherited bindings from an ancestor SkelRoot.
private func injectSkinningIntoPrim(
    named primName: String,
    rootPrim: String,
    in text: inout String,
    influences: MeshResource.JointInfluences,
    influencesPerVertex: Int
) {
    let meshMarker = "def Mesh \"\(primName)\""

    // Step 1: Add SkelBindingAPI to the mesh prim's apiSchemas metadata block.
    guard let markerRange = text.range(of: meshMarker) else { return }
    let afterMarker = markerRange.upperBound
    guard let bodyBrace = findPrimBodyBrace(in: text, from: afterMarker) else { return }
    let metaRange = afterMarker..<bodyBrace

    // MDLAsset writes `prepend apiSchemas = ["MaterialBindingAPI"]` for meshes with materials.
    // Insert SkelBindingAPI at the front of the existing list; fall back to creating a new entry.
    if let apiRange = text.range(of: "prepend apiSchemas = [", range: metaRange) {
        text.insert(contentsOf: "\"SkelBindingAPI\", ", at: apiRange.upperBound)
    } else if let lastParen = text[metaRange].lastIndex(of: ")") {
        text.insert(contentsOf: "    prepend apiSchemas = [\"SkelBindingAPI\"]\n", at: lastParen)
    }

    // Step 2: Re-find body brace after the metadata mutation shifted indices.
    guard let newMarkerRange = text.range(of: meshMarker) else { return }
    guard let newBodyBrace = findPrimBodyBrace(in: text, from: newMarkerRange.upperBound) else { return }

    // Step 3: Find the closing brace of the mesh body.
    var closingBrace = text.index(after: newBodyBrace)
    var depth = 1
    while closingBrace < text.endIndex, depth > 0 {
        switch text[closingBrace] {
        case "{": depth += 1; closingBrace = text.index(after: closingBrace)
        case "}": depth -= 1; if depth > 0 { closingBrace = text.index(after: closingBrace) }
        default:  closingBrace = text.index(after: closingBrace)
        }
    }

    // Step 4: Build skinning primvars.
    // USDZ / RealityKit supports at most 4 joint influences per vertex.
    // If the source has more (e.g. ipv=5), keep the top 4 by weight and renormalize.
    let rawIPV = influencesPerVertex
    let targetIPV = min(rawIPV, 4)
    // elementSize = 0 is invalid USD and can cause .importFailureWithURL on load.
    guard targetIPV > 0 else { return }
    let elements = influences.influences.elements
    let numVerts = rawIPV > 0 ? elements.count / rawIPV : 0

    var indices = [Int]()
    var weights = [Float]()
    indices.reserveCapacity(numVerts * targetIPV)
    weights.reserveCapacity(numVerts * targetIPV)

    for v in 0..<numVerts {
        let base = v * rawIPV
        var pairs = (0..<rawIPV).map { i in
            (idx: elements[base + i].jointIndex, wgt: elements[base + i].weight)
        }
        if rawIPV > targetIPV {
            pairs.sort { $0.wgt > $1.wgt }
            pairs = Array(pairs.prefix(targetIPV))
            let total = pairs.reduce(Float(0)) { $0 + $1.wgt }
            if total > 0 { pairs = pairs.map { (idx: $0.idx, wgt: $0.wgt / total) } }
        }
        for pair in pairs { indices.append(pair.idx); weights.append(pair.wgt) }
    }
    let ipv = targetIPV

    let ind2 = "        "
    let skinText = "\n" +
        "\(ind2)rel skel:skeleton = </\(rootPrim)/skeleton>\n" +
        "\(ind2)int[] primvars:skel:jointIndices (\n" +
        "\(ind2)    elementSize = \(ipv)\n" +
        "\(ind2)    interpolation = \"vertex\"\n" +
        "\(ind2)) = [\(indices.map { String($0) }.joined(separator: ", "))]\n" +
        "\(ind2)float[] primvars:skel:jointWeights (\n" +
        "\(ind2)    elementSize = \(ipv)\n" +
        "\(ind2)    interpolation = \"vertex\"\n" +
        "\(ind2)) = [\(weights.map { String($0) }.joined(separator: ", "))]\n"

    text.insert(contentsOf: skinText, at: closingBrace)
}

/// Packages all files in stagingDir into a USDZ ZIP archive.
/// USDZ requires each file's data to begin at a 64-byte-aligned offset within the archive.
private func packageAsUSDZ(stagingDir: URL, to url: URL) throws {
    let files = try FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
    guard files.contains(where: { $0.pathExtension == "usda" }) else {
        throw ModelIOWriteError.exportFailed(url)
    }

    // USDA must be first entry for USDZ validity; remaining files sorted alphabetically
    let sorted = files.sorted { a, b in
        if a.pathExtension == "usda" { return true }
        if b.pathExtension == "usda" { return false }
        return a.lastPathComponent < b.lastPathComponent
    }

    var zip = Data()
    var centralDirectory = Data()
    var fileCount: UInt16 = 0

    for fileURL in sorted {
        let fileData = try Data(contentsOf: fileURL)
        let filenameBytes = Data(fileURL.lastPathComponent.utf8)
        let crc = zipCRC32(fileData)
        let size = UInt32(fileData.count)
        let localHeaderOffset = UInt32(zip.count)

        // USDZ spec: each file's data must start at a 64-byte-aligned offset.
        // Local file header = 30 bytes fixed + filename + extra field; pad extra field to align data.
        let dataStartWithoutExtra = zip.count + 30 + filenameBytes.count
        let paddingNeeded = (64 - (dataStartWithoutExtra % 64)) % 64
        let alignmentPadding = Data(repeating: 0, count: paddingNeeded)

        // Local file header
        zip.appendLE(UInt32(0x04034b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(crc); zip.appendLE(size); zip.appendLE(size)
        zip.appendLE(UInt16(filenameBytes.count)); zip.appendLE(UInt16(paddingNeeded))
        zip.append(filenameBytes)
        zip.append(alignmentPadding)
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
