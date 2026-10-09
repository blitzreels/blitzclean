// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BlitzClean",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "BlitzClean", targets: ["BlitzClean"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
  ],
  targets: [
    .executableTarget(
      name: "BlitzClean",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
    .testTarget(name: "BlitzCleanTests", dependencies: ["BlitzClean"]),
  ]
)
