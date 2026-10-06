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
  targets: [
    .executableTarget(name: "BlitzClean"),
    .testTarget(name: "BlitzCleanTests", dependencies: ["BlitzClean"]),
  ]
)
