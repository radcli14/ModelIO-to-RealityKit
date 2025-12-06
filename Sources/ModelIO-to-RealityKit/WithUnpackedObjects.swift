//
//  WithUnpackedObjects.swift
//  Model3DLoader
//
//  Created by Eliott Radcliffe on 12/3/25.
//

import Foundation
import ModelIO

public protocol WithUnpackedObjects {
    var objects: [MDLObject] { get }
}

public extension WithUnpackedObjects {
    /// The `MDLMesh` instances inside of the `objects` array
    var meshes: [MDLMesh] {
        objects.compactMap { $0 as? MDLMesh }
    }
}

extension MDLAsset: WithUnpackedObjects {
    /// The array of `MDLObject` found in this `MDLAsset`
    public var objects: [MDLObject] {
        var result = [MDLObject]()
        for i in 0 ..< self.count {
            result.append(self.object(at: i))
        }
        return result
    }
}

extension MDLObject: WithUnpackedObjects {
    /// Unpack the children to an array of `MDLObject`
    public var objects: [MDLObject] {
        var result = [MDLObject]()
        for i in 0 ..< children.count {
            result.append(children[i])
        }
        return result
    }
}
