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
}
