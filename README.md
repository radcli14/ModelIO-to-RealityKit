# ModelIO-to-RealityKit
Extensions to create RealityKit entities from STL, OBJ, PLY, and ABC formats supported in ModelIO

## Background

RealityKit provides native support and entity initializers for Universal Scene Description (USDA, USDC, and USDZ) formatted 3D model files.
In one of my own projects, [Augmented Reality Mobile Robotics (ARMOR)](https://www.dc-engineer.com/armor) I found I needed to support other 3D modeling formats, such as STL and OBJ, that were commonly used in the [ROS](https://www.ros.org)-compatible Unified Robot Description Format (URDF).
These file formats are supported by Apple's [ModelIO](https://developer.apple.com/documentation/modelio), which is a lower level package that loads in the models as raw data and buffers, using data types that trace back to older Objective C classes.
While there is not always an exact mapping for all 3D model formats, there is sufficient data to be unpacked from the ModelIO types to be able to generate the meshes and materials to be rendered in RealityKit.

This package contains a variety of extensions, aimed to be utilities that map the types used in ModelIO to more modern Swift arrays, and with more strict type definition, all with the intent of conversion into RealityKit.
You may refer to the individual extensions and documentation as you wish, though I recommend you stick to the minimal example at the end of this readme.
Of course, if you wish to improve on these extensions, I welcome any and all contributions.

## Installation

The package may be installed using Swift Package Manager, in XCode, as follows:github.com/radcli14/ModelIO-to-RealityKit
1. From the `File` menu, select `Add Package Dependencies`.
2. In the search bar in the upper right, enter `https://github.com/radcli14/ModelIO-to-RealityKit`.
3. Make sure your project is selected in the `Add to Project` line, then click the `Add Package` button in the lower right.
4. Make sure your target is selected in the `Add to Target` line, then click the `Add Package` button again.

## Minimal Example

The simplest entry point is to use the extension `.fromMDLAsset` with a valid `URL` for a file that can be handled by ModelIO.
That extension is `async`, and is formatted as follows:

```swift
ModelEntity.fromMDLAsset(url: URL)
```

In the example below, the project contains a Wavefront Object file named `shiny.obj` in its asset bundle.
The usage of a URL from the asset bundle is a convenience, though this extension should work for any valid file URL that the app can access.
This URL is used to initialize a `ModelEntity`, which is rendered in a `RealityView`.

```swift
import SwiftUI
import RealityKit
import ModelIO_to_RealityKit

struct ContentView: View {
    var body: some View {
        NavigationStack {
            RealityView { content in
                if let url = Bundle.main.url(forResource: "shiny", withExtension: "obj"),
                   let entity = await ModelEntity.fromMDLAsset(url: url) {
                    content.add(entity)
                }
            }
            .realityViewCameraControls(.orbit)
            .navigationTitle("Model3DLoader")
        }
    }
}
```

![Screenshot](screenshot.png)
