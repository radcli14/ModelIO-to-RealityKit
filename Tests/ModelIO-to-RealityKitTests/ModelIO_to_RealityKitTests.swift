import Testing
import Foundation
@preconcurrency import RealityKit
@testable import ModelIO_to_RealityKit

@Test func example() async throws {
    // Get the URL of a test .obj file in the test bundle
    guard let url = Bundle.module.url(forResource: "xyzBlock", withExtension: "obj") else {
        print("failed to get URL")
        return
    }
    
    // Verify that the file exists
    #expect(FileManager.default.fileExists(atPath: url.path), "url: \(url.absoluteString) does not exist")

    // Get the entity, and verify its mesh bounds are correct
    let entity = await ModelEntity.fromMDLAsset(url: url)
    let minBounds = await entity?.model?.mesh.bounds.min
    let maxBounds = await entity?.model?.mesh.bounds.max
    #expect(minBounds == SIMD3<Float>(-0.3, -0.4, -0.1), "minBounds do not match expectation")
    #expect(maxBounds == SIMD3<Float>(0.3, 0.4, 0.1), "maxBounds do not match expectation")
}
