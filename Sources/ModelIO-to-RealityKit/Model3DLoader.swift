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
class Model3DLoader {
    let url: URL
    let asset: MDLAsset
    
    init(filename: String, fileExtension: String) {
        url = Bundle.main.url(forResource: filename, withExtension: fileExtension)! // TODO: error handling
        
        // Load the asset using Model I/O.
        asset = MDLAsset(url: url)
    }
    
    func loadEntity() async -> ModelEntity? {
        await asset.getModelEntity()
    }
}
