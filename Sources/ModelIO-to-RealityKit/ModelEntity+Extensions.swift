//
//  ModelEntity+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/6/25.
//

import Foundation
import ModelIO
import RealityKit

public extension Entity {
    /// Create an `Entity` from a `URL` for a file that is of a type supported by `ModelIO`
    @MainActor
    static func fromMDLAsset(url: URL) async throws -> Entity {
        let asset = MDLAsset(url: url)
        return try await asset.getEntity()
    }

    /// Create an `Entity` from raw file data in a format supported by `ModelIO`
    /// - Parameters:
    ///   - data: The raw file data (STL, OBJ, PLY, or ABC format)
    ///   - format: File format extension (e.g. "stl", "obj", "ply", "abc")
    @MainActor
    static func fromMDLAsset(
        data: Data,
        format: String
    ) async throws -> Entity {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try data.write(to: tempURL)
        return try await Entity.fromMDLAsset(url: tempURL)
    }
}
