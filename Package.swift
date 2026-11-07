// swift-tools-version:5.9
import PackageDescription

// Tracive SDK for Swift — phase 1 (OAuth mode).
//
// ## Zero third-party dependencies, by design
//
// There is deliberately **no `dependencies:` array** on this package, and there never should be.
// That is the Swift SDK's headline property: a partner integrating a fraud-check SDK
// is taking on our supply chain, and every transitive package is another party who can ship code
// into their app. Everything the SDK needs already lives in the platform:
//
// | Need | Platform facility |
// |---|---|
// | HTTP | `URLSession` (Foundation) |
// | JSON | `Codable` (Foundation) |
// | SHA-256, AES-GCM, HKDF, P-256 | CryptoKit |
// | Local storage | system `libsqlite3` — see `linkedLibrary("sqlite3")` below |
// | Key storage | Security (Keychain) + Secure Enclave |
//
// In particular there is **no SQLCipher**: the encryption story here is per-row AES-GCM with a
// Keychain-held data key, not an encrypted database file. See `Docs/caching.md`.
//
// All of that describes the `TraciveSDK` product. `TraciveSDKExtended` and `TraciveSDKExtendedUI`
// add the `TraciveReportCore` binary, which carries avifkit and the Kotlin runtime, because the
// report pipeline is shared with the other platforms. A partner opts in by adding those products.
// Nothing from the binary links into an app that does not, but SwiftPM downloads its zip for every
// resolve of this package, whichever products are used.

// Scripts/swift-binary-target.sh rewrites this declaration when a release is cut, so a partner
// resolving a tag gets the url form and never needs a local path.
// swift-binary-target:begin
let reportCore: Target = .binaryTarget(
  name: "TraciveReportCore",
  path: "Frameworks/TraciveReportCore.xcframework"
)
// swift-binary-target:end

let package = Package(
  name: "TraciveSDK",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "TraciveSDK", targets: ["TraciveSDK"]),
    .library(name: "TraciveSDKExtended", targets: ["TraciveSDKExtended"]),
    .library(name: "TraciveSDKExtendedUI", targets: ["TraciveSDKExtendedUI"]),
  ],
  targets: [
    reportCore,
    .target(
      name: "TraciveSDK",
      path: "Sources/TraciveSDK",
      // The system SQLite that ships with iOS and macOS. `import SQLite3` resolves against the SDK's
      // own module map; this line only tells the linker where the symbols live. It is not a package
      // dependency and pulls in no source we do not control.
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "TraciveSDKExtended",
      dependencies: ["TraciveSDK", "TraciveReportCore"],
      path: "Sources/TraciveSDKExtended",
      resources: [.copy("PrivacyInfo.xcprivacy")]
    ),
    .target(
      name: "TraciveSDKExtendedUI",
      dependencies: ["TraciveSDKExtended"],
      path: "Sources/TraciveSDKExtendedUI",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "TraciveSDKTests",
      dependencies: ["TraciveSDK"],
      path: "Tests/TraciveSDKTests",
      // `query-grammar-vectors.json` is the vendored cross-language anti-drift contract. Processing
      // the directory puts it in the generated resource bundle, so `Bundle.module` finds it at
      // `query-grammar-vectors.json` (SwiftPM flattens processed resource paths).
      resources: [.process("Fixtures")]
    ),
    // The core has no macOS slice, so these two compile to nothing on a Mac. `swift test` builds
    // every test target whatever `--filter` says, so an unconditional dependency here would fail it.
    .testTarget(
      name: "TraciveSDKExtendedTests",
      dependencies: [.target(name: "TraciveSDKExtended", condition: .when(platforms: [.iOS]))],
      path: "Tests/TraciveSDKExtendedTests"
    ),
    .testTarget(
      name: "TraciveSDKExtendedUITests",
      dependencies: [.target(name: "TraciveSDKExtendedUI", condition: .when(platforms: [.iOS]))],
      path: "Tests/TraciveSDKExtendedUITests"
    ),
  ]
)
