import Testing
import Foundation
import ModelIO
@preconcurrency import RealityKit
@testable import ModelIO_to_RealityKit

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

    let loaded = try await ModelEntity.fromMDLAsset(url: tmpURL)
    let roundtripped = loaded.model?.materials.first as? PhysicallyBasedMaterial

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

@Test @MainActor func testTextureEmbeddedInUSDZ() async throws {
    let objURL = try #require(Bundle.module.url(forResource: "xyzBlock", withExtension: "obj"), "xyzBlock.obj not found in test bundle")

    let entity = try await ModelEntity.fromMDLAsset(url: objURL)
    let hasTexture = entity.model?.materials.first.flatMap { $0 as? PhysicallyBasedMaterial }?.baseColor.texture != nil
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
