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
    /// All `MDLMesh` instances in the object tree, searched recursively.
    /// A flat search misses meshes nested under Xform/Scope nodes (e.g. USDA exports).
    var meshes: [MDLMesh] {
        objects.flatMap { object -> [MDLMesh] in
            var found = object.meshes  // recurse into children first
            if let mesh = object as? MDLMesh { found.insert(mesh, at: 0) }
            return found
        }
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
