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

        for modelEntity in modelEntities {
            guard let models = modelEntity.model?.mesh.contents.models else { continue }
            let materials = modelEntity.model?.materials ?? []
            let worldTransform = modelEntity.transformMatrix(relativeTo: nil)
            let normalMatrix = simd_float3x3(columns: (
                SIMD3<Float>(worldTransform[0].x, worldTransform[0].y, worldTransform[0].z),
                SIMD3<Float>(worldTransform[1].x, worldTransform[1].y, worldTransform[1].z),
                SIMD3<Float>(worldTransform[2].x, worldTransform[2].y, worldTransform[2].z)
            ))
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
                    posAttr.name = MDLVertexAttributePosition; posAttr.format = .float3
                    posAttr.offset = 0; posAttr.bufferIndex = 0
                    let normAttr = MDLVertexAttribute()
                    normAttr.name = MDLVertexAttributeNormal; normAttr.format = .float3
                    normAttr.offset = 12; normAttr.bufferIndex = 0
                    let uvAttr = MDLVertexAttribute()
                    uvAttr.name = MDLVertexAttributeTextureCoordinate; uvAttr.format = .float2
                    uvAttr.offset = 24; uvAttr.bufferIndex = 0
                    vertexDescriptor.attributes = NSMutableArray(array: [posAttr, normAttr, uvAttr])
                    let layout = MDLVertexBufferLayout(); layout.stride = 32
                    vertexDescriptor.layouts = NSMutableArray(array: [layout])

                    var vertexData = Data()
                    vertexData.reserveCapacity(positions.count * 32)
                    for i in 0..<positions.count {
                        let p = positions[i]
                        let pw = worldTransform * SIMD4<Float>(p.x, p.y, p.z, 1)
                        var xyz = (pw.x, pw.y, pw.z)
                        withUnsafeBytes(of: &xyz) { vertexData.append(contentsOf: $0) }
                        let nw: SIMD3<Float> = (normals?.count == positions.count)
                            ? normalize(normalMatrix * normals![i])
                            : .zero
                        var nxyz = (nw.x, nw.y, nw.z)
                        withUnsafeBytes(of: &nxyz) { vertexData.append(contentsOf: $0) }
                        let uv: SIMD2<Float> = (uvs?.count == positions.count) ? uvs![i] : .zero
                        var uvxy = (uv.x, uv.y)
                        withUnsafeBytes(of: &uvxy) { vertexData.append(contentsOf: $0) }
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
                }
            }
        }

        if isUSDZ {
            let usda = stagingDir!.appendingPathComponent("model.usda")
            try asset.export(to: usda)
            // MDLAsset's empty-init assumes centimeters, so it writes a 0.01 root scale. Strip it
            // because vertex positions are already in RealityKit world-space meters.
            try stripRootScale(in: usda)
            // MDLAsset.export drops urlValue on MDLMaterialProperty, so texture UsdUVTexture nodes
            // must be injected by replacing the Materials scope after the fact.
            if materialRecords.contains(where: \.hasTextures) {
                try patchMaterialsSection(in: usda, records: materialRecords)
            }
            try packageAsUSDZ(stagingDir: stagingDir!, to: url)
        } else {
            try asset.export(to: url)
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

/// Removes the spurious 0.01 root scale that MDLAsset.export writes on the root Xform prim.
/// MDLAsset's empty init assumes centimeters; the export encodes that assumption as a (0.01, 0.01, 0.01)
/// xformOp:scale, but our vertices are already in RealityKit world-space meters.
private func stripRootScale(in usda: URL) throws {
    var text = try String(contentsOf: usda, encoding: .utf8)

    // Locate the root Xform and its opening brace
    guard let xformMarker = text.range(of: "def Xform ") else { return }
    guard let openBrace = text[xformMarker.lowerBound...].firstIndex(of: "{") else { return }
    let bodyStart = text.index(after: openBrace)

    // Limit the search to the root prim's direct properties, before the first nested child prim
    let nestedDefEnd = text[bodyStart...].range(of: "\n    def ")?.lowerBound ?? text.endIndex
    let rootProps = text[bodyStart..<nestedDefEnd]

    guard let scaleRange = rootProps.range(of: "xformOp:scale = (") else { return }

    // Find the full line containing xformOp:scale
    var lineStart = scaleRange.lowerBound
    while lineStart > text.startIndex, text[text.index(before: lineStart)] != "\n" {
        lineStart = text.index(before: lineStart)
    }
    var lineEnd = scaleRange.upperBound
    while lineEnd < text.endIndex, text[lineEnd] != "\n" {
        lineEnd = text.index(after: lineEnd)
    }
    if lineEnd < text.endIndex { lineEnd = text.index(after: lineEnd) }

    let indent = String(text[lineStart..<scaleRange.lowerBound])
    text.replaceSubrange(lineStart..<lineEnd, with: "\(indent)float3 xformOp:scale = (1, 1, 1)\n")

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
            let slots: [(key: String, shaderName: String, output: String)] = [
                ("diffuseColor",  "baseColorTex", "token outputs:rgb"),
                ("normal",        "normalTex",    "token outputs:rgb"),
                ("roughness",     "roughnessTex", "token outputs:r"),
                ("metallic",      "metallicTex",  "token outputs:r"),
                ("emissiveColor", "emissiveTex",  "token outputs:rgb"),
                ("occlusion",     "occlusionTex", "token outputs:r"),
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
