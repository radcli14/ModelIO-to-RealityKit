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
