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
let package = Package(
  name: "TraciveSDK",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "TraciveSDK", targets: ["TraciveSDK"])
  ],
  targets: [
    .target(
      name: "TraciveSDK",
      path: "Sources/TraciveSDK",
      // The system SQLite that ships with iOS and macOS. `import SQLite3` resolves against the SDK's
      // own module map; this line only tells the linker where the symbols live. It is not a package
      // dependency and pulls in no source we do not control.
      linkerSettings: [.linkedLibrary("sqlite3")]
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
  ]
)
