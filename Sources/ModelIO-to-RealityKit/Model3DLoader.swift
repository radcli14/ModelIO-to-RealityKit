//
//  Model3DLoader.swift
//  ModelIO-to-RealityKit
//
//  Created by Eliott Radcliffe on 12/5/25.
//

import Foundation
import ModelIO
import RealityKit

/// Handles processing an asset created using `ModelIO` to create a `RealityKit.Entity`
public class Model3DLoader {
    public let url: URL
    public let asset: MDLAsset
    
    public init(filename: String, fileExtension: String) {
        url = Bundle.main.url(forResource: filename, withExtension: fileExtension)! // TODO: error handling
        
        // Load the asset using Model I/O.
        asset = MDLAsset(url: url)
    }
    
    @MainActor
    public func loadEntity() async -> ModelEntity? {
        await asset.getModelEntity()
    }
}
