import Testing
import Foundation
@preconcurrency import RealityKit
@testable import ModelIO_to_RealityKit

@Test func testLoadObj() async throws {
    // Get the URL of a test .obj file in the test bundle
    guard let url = Bundle.module.url(forResource: "xyzBlock", withExtension: "obj") else {
        print("failed to get URL")
        return
    }
    
    // Verify that the file exists
    #expect(FileManager.default.fileExists(atPath: url.path), "url: \(url.absoluteString) does not exist")

    // Get the entity, and verify its mesh bounds are correct
    let entity = try await Entity.fromMDLAsset(url: url)
    let modelEntity = entity as? ModelEntity
    let minBounds = await modelEntity?.model?.mesh.bounds.min
    let maxBounds = await modelEntity?.model?.mesh.bounds.max
    #expect(minBounds == SIMD3<Float>(-0.3, -0.4, -0.1), "minBounds do not match expectation")
    #expect(maxBounds == SIMD3<Float>(0.3, 0.4, 0.1), "maxBounds do not match expectation")

    // Verify that texture resources are valid
    let material = await modelEntity?.model?.materials.first as? PhysicallyBasedMaterial
    let texture = material?.baseColor.texture
    let width = await texture?.resource.width
    let height = await texture?.resource.height
    #expect(width == 1024, "baseColor texture did not have correct height")
    #expect(height == 1024, "baseColor texture did not have correct height")
}
