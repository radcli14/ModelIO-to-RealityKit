//
//  ModelEntity+Extensions.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/6/25.
//

import Foundation
import ModelIO
import RealityKit

public extension ModelEntity {
    /// Create a `ModelEntity` from a `URL` for a file that is of a type supported by `ModelIO`
    @MainActor
    static func fromMDLAsset(url: URL) async -> ModelEntity? {
        // Load the asset using Model I/O.
        let asset = MDLAsset(url: url)
        
        // Asynchronously get its `ModelEntity`
        return await asset.getModelEntity()
    }
    
    /// Load ModelEntity from Data instead of URL
    /// - Parameters:
    ///   - data: The raw file data (STL, OBJ, PLY, or ABC format)
    ///   - format: File format extension ("stl", "obj", "ply", or "abc")
    /// - Returns: ModelEntity if successful, nil otherwise
    @MainActor
    static func fromMDLAsset(
        data: Data,
        format: String
    ) async -> ModelEntity? {
        // Create temporary file URL
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format)

        do {
            // Write data to temporary file
            try data.write(to: tempURL)

            // Load using existing URL-based method
            let entity = await ModelEntity.fromMDLAsset(url: tempURL)

            // Clean up temporary file
            try? FileManager.default.removeItem(at: tempURL)

            return entity
        } catch {
            print("Error in fromMDLAsset(data:format:): \(error.localizedDescription)")
            
            // Cleanup on error
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }
}
