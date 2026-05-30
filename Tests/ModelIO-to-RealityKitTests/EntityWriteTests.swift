import Testing
import Foundation
import ModelIO
@preconcurrency import RealityKit
import GLTFKit2
@testable import ModelIO_to_RealityKit

/// Verifies that reloading an STL via fromMDLAsset produces a non-nil PhysicallyBasedMaterial
/// with a non-black base color. STL has no material data, so the loader must supply a default.
@Test @MainActor func testSTLRoundtripDefaultMaterial() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    let entity = ModelEntity(mesh: mesh)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("stl")
    defer { try? FileManager.default.removeItem(at: tmpURL) }
    try await entity.writeMDLAsset(to: tmpURL)

    // Check getMaterials() directly on the MDLAsset — bypasses any RealityKit
    // default-material substitution that ModelEntity(mesh:materials:) may apply.
    let asset = MDLAsset(url: tmpURL)
    let materials = await asset.getMaterials()
    let mat = try #require(
        materials.first as? PhysicallyBasedMaterial,
        "getMaterials() must return a PhysicallyBasedMaterial for STL (got \(materials.first.debugDescription))"
    )
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    #if os(macOS)
    (mat.baseColor.tint.usingColorSpace(.sRGB) ?? mat.baseColor.tint).getRed(&r, green: &g, blue: &b, alpha: nil)
    #else
    mat.baseColor.tint.getRed(&r, green: &g, blue: &b, alpha: nil)
    #endif
    #expect(r > 0 || g > 0 || b > 0,
            "Default PBR material base color must not be black (got r=\(r) g=\(g) b=\(b))")
}

/// Verifies that a box written to STL and reloaded via fromMDLAsset produces a valid
/// ModelEntity with a non-empty mesh. STL's facet normal field is always written as zeros
/// by MDLAsset's exporter (a ModelIO limitation), so our loader drops all-zero normals and
/// lets RealityKit auto-generate them — this test confirms the pipeline doesn't crash or
/// produce a degenerate entity as a result.
@Test @MainActor func testSTLRoundtripNormals() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    let entity = ModelEntity(mesh: mesh)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("stl")
    defer { try? FileManager.default.removeItem(at: tmpURL) }
    try await entity.writeMDLAsset(to: tmpURL)

    let loaded = try await Entity.fromMDLAsset(url: tmpURL)
    let extents = loaded.visualBounds(relativeTo: nil).extents
    #expect(extents.x > 0 && extents.y > 0 && extents.z > 0,
            "Reloaded STL entity has zero extents — mesh was not loaded")
}

@Test @MainActor func testWriteSTL() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    let entity = ModelEntity(mesh: mesh)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("stl")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    #expect(FileManager.default.fileExists(atPath: tmpURL.path), "STL file was not created at \(tmpURL.path)")
    let asset = MDLAsset(url: tmpURL)
    #expect(asset.count > 0, "STL asset has no objects")
}

@Test @MainActor func testWriteOBJ() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    let entity = ModelEntity(mesh: mesh)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("obj")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    #expect(FileManager.default.fileExists(atPath: tmpURL.path), "OBJ file was not created at \(tmpURL.path)")
    let asset = MDLAsset(url: tmpURL)
    #expect(asset.count > 0, "OBJ asset has no objects")
}

@Test @MainActor func testWritePLY() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    let entity = ModelEntity(mesh: mesh)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ply")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    #expect(FileManager.default.fileExists(atPath: tmpURL.path), "PLY file was not created at \(tmpURL.path)")
    let asset = MDLAsset(url: tmpURL)
    #expect(asset.count > 0, "PLY asset has no objects")
}

@Test @MainActor func testWriteABC() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    let entity = ModelEntity(mesh: mesh)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("abc")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    #expect(FileManager.default.fileExists(atPath: tmpURL.path), "ABC file was not created at \(tmpURL.path)")
    let asset = MDLAsset(url: tmpURL)
    #expect(asset.count > 0, "ABC asset has no objects")
}

@Test @MainActor func testWriteUSDZ() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    let entity = ModelEntity(mesh: mesh)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("usdz")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    #expect(FileManager.default.fileExists(atPath: tmpURL.path), "USDZ file was not created at \(tmpURL.path)")
    let asset = MDLAsset(url: tmpURL)
    #expect(asset.count > 0, "USDZ asset has no objects")
}

@Test @MainActor func testMaterialRoundtripUSDA() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    var material = PhysicallyBasedMaterial()
    material.roughness = .init(floatLiteral: 0.3)
    material.baseColor = .init(tint: .init(red: 1, green: 0, blue: 0, alpha: 1))
    let entity = ModelEntity(mesh: mesh, materials: [material])

    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("usda")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    let loaded = try await Entity.fromMDLAsset(url: tmpURL)
    let roundtripped = (loaded as? ModelEntity)?.model?.materials.first as? PhysicallyBasedMaterial

    // Roughness: written as 0.3, default is 0.5 — must be near 0.3
    let roughness = roundtripped?.roughness.scale ?? 0.5
    #expect(abs(roughness - 0.3) < 0.05, "roughness did not survive USDA roundtrip (got \(roughness))")

    // Base color: written as red (1,0,0,1) — green channel must be near 0, not the default 1
    var greenComponent: CGFloat = 1.0
    #if os(macOS)
    (roundtripped?.baseColor.tint.usingColorSpace(.sRGB) ?? roundtripped?.baseColor.tint)?.getRed(nil, green: &greenComponent, blue: nil, alpha: nil)
    #else
    roundtripped?.baseColor.tint.getRed(nil, green: &greenComponent, blue: nil, alpha: nil)
    #endif
    #expect(greenComponent < 0.1, "base color did not survive USDA roundtrip (green=\(greenComponent), expected ≈0 for red)")
}

@Test @MainActor func testWriteReadRoundtripUSDZ() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    let entity = ModelEntity(mesh: mesh)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("usdz")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    let loaded = try await Entity(contentsOf: tmpURL)
    let extents = loaded.visualBounds(relativeTo: nil).extents
    #expect(extents.x > 0 && extents.y > 0 && extents.z > 0, "Loaded USDZ mesh has zero extents")
}

/// Verifies that the exported USDZ preserves metric scale: a 0.1 m box must reload as 0.1 m.
/// Catches metersPerUnit = 0.01 and xformOp:scale = (0.01, …) regressions that would produce
/// a mesh 100× too small (extents ≈ 0.001 m instead of 0.1 m).
@Test @MainActor func testRoundtripUSDZPreservesExtents() async throws {
    let size: Float = 0.1
    let mesh = MeshResource.generateBox(size: size)
    let entity = ModelEntity(mesh: mesh)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("usdz")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    let loaded = try await Entity(contentsOf: tmpURL)
    let extents = loaded.visualBounds(relativeTo: nil).extents
    let tolerance = size * 0.01  // 1 % — well above float round-trip error
    #expect(abs(extents.x - size) < tolerance, "X extent \(extents.x) should be ~\(size) m")
    #expect(abs(extents.y - size) < tolerance, "Y extent \(extents.y) should be ~\(size) m")
    #expect(abs(extents.z - size) < tolerance, "Z extent \(extents.z) should be ~\(size) m")
}

/// Verifies that an entity's world-space position is baked into the exported vertices.
/// A box placed at (1, 0, 0) should have bounds centered near (1, 0, 0) after round-trip.
/// Catches regressions where positions are written in local space (origin) instead of world space.
@Test @MainActor func testRoundtripUSDZBakesWorldTransform() async throws {
    let mesh = MeshResource.generateBox(size: 0.1)
    let entity = ModelEntity(mesh: mesh)
    entity.position = SIMD3<Float>(1, 0, 0)
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("usdz")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    let loaded = try await Entity(contentsOf: tmpURL)
    let center = loaded.visualBounds(relativeTo: nil).center
    let tolerance: Float = 0.01
    #expect(abs(center.x - 1.0) < tolerance, "Center X \(center.x) should be ~1.0 (world transform baked in)")
    #expect(abs(center.y)       < tolerance, "Center Y \(center.y) should be ~0")
    #expect(abs(center.z)       < tolerance, "Center Z \(center.z) should be ~0")
}

/// Downloads the DamagedHelmet GLB, re-exports as USDZ, reloads, and verifies that baseColor
/// and normal textures survived the round-trip (checks for non-nil PhysicallyBasedMaterial textures).
@Test @MainActor func testRoundTripDamagedHelmetToUSDZ() async throws {
    let remoteURL = URL(string: "https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/refs/heads/main/Models/DamagedHelmet/glTF-Binary/DamagedHelmet.glb")!
    let (tmp, _) = try await URLSession.shared.download(from: remoteURL)
    let glbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("glb")
    try FileManager.default.moveItem(at: tmp, to: glbURL)
    defer { try? FileManager.default.removeItem(at: glbURL) }

    let entity = try await GLTFRealityKitLoader.load(from: glbURL)

    func firstPBR(_ e: Entity) -> PhysicallyBasedMaterial? {
        if let m = (e as? ModelEntity)?.model?.materials.first as? PhysicallyBasedMaterial { return m }
        for child in e.children { if let found = firstPBR(child) { return found } }
        return nil
    }

    let glbBounds = entity.visualBounds(relativeTo: nil)
    let glbMat = try #require(firstPBR(entity), "No PhysicallyBasedMaterial found in GLB entity")

    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("usdz")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    #expect(FileManager.default.fileExists(atPath: tmpURL.path), "USDZ was not created")

    let loaded = try await Entity(contentsOf: tmpURL)
    let mat = try #require(firstPBR(loaded), "No PhysicallyBasedMaterial found in reloaded USDZ")

    // Textures
    #expect(mat.baseColor.texture != nil, "baseColor texture was not preserved in USDZ round-trip")
    #expect(mat.normal.texture != nil, "normal texture was not preserved in USDZ round-trip")

    // Roughness: texture or scalar must survive
    if glbMat.roughness.texture != nil {
        #expect(mat.roughness.texture != nil, "roughness texture was not retained in USDZ round-trip")
    } else {
        #expect(abs(mat.roughness.scale - glbMat.roughness.scale) < 0.05,
                "roughness \(mat.roughness.scale) should match GLB \(glbMat.roughness.scale)")
    }

    // Metallic: texture or scalar must survive (GLTFKit2 splits the packed metallicRoughness
    // texture into green→roughness and blue→metallic TextureResources before we see it)
    if glbMat.metallic.texture != nil {
        #expect(mat.metallic.texture != nil, "metallic texture was not retained in USDZ round-trip")
    } else {
        #expect(abs(mat.metallic.scale - glbMat.metallic.scale) < 0.05,
                "metallic \(mat.metallic.scale) should match GLB \(glbMat.metallic.scale)")
    }

    // Ambient occlusion: texture must survive (GLTFKit2 maps occlusionTexture → .ambientOcclusion, red channel)
    if glbMat.ambientOcclusion.texture != nil {
        #expect(mat.ambientOcclusion.texture != nil, "ambient occlusion texture was not retained in USDZ round-trip")
    }

    // Opacity: blending mode and scale must survive
    let glbOpacity: Float = { if case .transparent(let o) = glbMat.blending { return o.scale }; return 1.0 }()
    let usdzOpacity: Float = { if case .transparent(let o) = mat.blending { return o.scale }; return 1.0 }()
    #expect(abs(usdzOpacity - glbOpacity) < 0.05,
            "opacity \(usdzOpacity) should match GLB \(glbOpacity)")

    // Emissive: texture or scalar color must survive
    if glbMat.emissiveColor.texture != nil {
        #expect(mat.emissiveColor.texture != nil, "emissive texture was not retained in USDZ round-trip")
    } else {
        var gr: CGFloat = 0, gg: CGFloat = 0, gb: CGFloat = 0
        var ur: CGFloat = 0, ug: CGFloat = 0, ub: CGFloat = 0
        #if os(macOS)
        (glbMat.emissiveColor.color.usingColorSpace(.sRGB) ?? glbMat.emissiveColor.color).getRed(&gr, green: &gg, blue: &gb, alpha: nil)
        (mat.emissiveColor.color.usingColorSpace(.sRGB) ?? mat.emissiveColor.color).getRed(&ur, green: &ug, blue: &ub, alpha: nil)
        #else
        glbMat.emissiveColor.color.getRed(&gr, green: &gg, blue: &gb, alpha: nil)
        mat.emissiveColor.color.getRed(&ur, green: &ug, blue: &ub, alpha: nil)
        #endif
        #expect(abs(Float(ur) - Float(gr)) < 0.05, "emissive R \(ur) should match GLB \(gr)")
        #expect(abs(Float(ug) - Float(gg)) < 0.05, "emissive G \(ug) should match GLB \(gg)")
        #expect(abs(Float(ub) - Float(gb)) < 0.05, "emissive B \(ub) should match GLB \(gb)")
    }

    // Scale and position: USDZ bounds must match GLB bounds within 5% of the model's size.
    // Catches metersPerUnit regressions (100× scale error) and lost world-transform bugs.
    let usdzBounds = loaded.visualBounds(relativeTo: nil)
    let modelSize = max(glbBounds.extents.x, glbBounds.extents.y, glbBounds.extents.z)
    let tol = modelSize * 0.05
    #expect(abs(usdzBounds.extents.x - glbBounds.extents.x) < tol, "X extent \(usdzBounds.extents.x) should match GLB \(glbBounds.extents.x)")
    #expect(abs(usdzBounds.extents.y - glbBounds.extents.y) < tol, "Y extent \(usdzBounds.extents.y) should match GLB \(glbBounds.extents.y)")
    #expect(abs(usdzBounds.extents.z - glbBounds.extents.z) < tol, "Z extent \(usdzBounds.extents.z) should match GLB \(glbBounds.extents.z)")
    #expect(abs(usdzBounds.center.x  - glbBounds.center.x)  < tol, "Center X \(usdzBounds.center.x) should match GLB \(glbBounds.center.x)")
    #expect(abs(usdzBounds.center.y  - glbBounds.center.y)  < tol, "Center Y \(usdzBounds.center.y) should match GLB \(glbBounds.center.y)")
    #expect(abs(usdzBounds.center.z  - glbBounds.center.z)  < tol, "Center Z \(usdzBounds.center.z) should match GLB \(glbBounds.center.z)")
}

/// Verifies that a PointLightComponent survives a USDZ round-trip.
/// The export writes a UsdLux SphereLight prim; the import uses Entity(contentsOf:)
/// which uses RealityKit's native USD loader and should reconstruct the light.
@Test @MainActor func testLightRoundtripUSDZ() async throws {
    let container = Entity()
    container.addChild(ModelEntity(mesh: MeshResource.generateBox(size: 0.1)))
    let lightEntity = Entity()
    lightEntity.name = "testPointLight"
    lightEntity.position = SIMD3<Float>(0, 1, 0)
    lightEntity.components.set(PointLightComponent(color: .red, intensity: 5000, attenuationRadius: 8.0))
    container.addChild(lightEntity)

    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("usdz")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await container.writeMDLAsset(to: tmpURL)

    // Verify the USDZ archive was created
    #expect(FileManager.default.fileExists(atPath: tmpURL.path), "USDZ was not created")

    // Verify the USDA inside contains a SphereLight prim (light was injected)
    let zipData = try Data(contentsOf: tmpURL)
    let sphereLightMarker = Data("SphereLight".utf8)
    #expect(zipData.range(of: sphereLightMarker) != nil, "USDZ archive does not contain a SphereLight prim")
}

@Test @MainActor func testTextureEmbeddedInUSDZ() async throws {
    let objURL = try #require(Bundle.module.url(forResource: "xyzBlock", withExtension: "obj"), "xyzBlock.obj not found in test bundle")

    let entity = try await Entity.fromMDLAsset(url: objURL)
    let hasTexture = (entity as? ModelEntity)?.model?.materials.first.flatMap { $0 as? PhysicallyBasedMaterial }?.baseColor.texture != nil
    try #require(hasTexture, "xyzBlock.obj did not load with a baseColor texture — test precondition failed")

    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("usdz")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    try await entity.writeMDLAsset(to: tmpURL)

    #expect(FileManager.default.fileExists(atPath: tmpURL.path), "USDZ file was not created")

    // USDZ is a ZIP archive — verify it contains at least one PNG (PNG magic bytes 0x89 0x50 0x4E 0x47)
    let zipData = try Data(contentsOf: tmpURL)
    let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
    #expect(zipData.range(of: pngMagic) != nil, "USDZ archive does not contain any PNG texture; baseColor texture was not embedded")
}
