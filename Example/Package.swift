// swift-tools-version:5.9
import PackageDescription

// A runnable, compiling example of the Tracive SDK.
//
// It is a separate package with a **path** dependency on the SDK rather than a folder inside the SDK
// target, for two reasons: it consumes the package exactly the way a partner app does, and CI builds
// it on every PR — so the sample code in the README cannot rot without turning something red.
//
// The whole example runs offline. There is no server to talk to (the Tracive Open API is not
// deployed), and an example that needs one would be a demo nobody can run.
let package = Package(
  name: "TraciveExample",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "TraciveExample", targets: ["TraciveExample"])
  ],
  dependencies: [
    // `name:` is supplied deliberately. Without it SwiftPM derives a path dependency's identity from
    // the directory it points at, so the target below would have to say
    // `package: "tracive-sdk-swift"` — hard-coding the checkout folder name into the build. Clone
    // the repo under any other name and the example stops resolving, with an error that names a
    // directory rather than the real problem. Pinning the name here decouples the two.
    .package(name: "TraciveSDK", path: "..")
  ],
  targets: [
    .target(
      name: "TraciveExample",
      dependencies: [.product(name: "TraciveSDK", package: "TraciveSDK")]
    )
  ]
)
