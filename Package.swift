// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BlitzClean",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "BlitzClean", targets: ["FreeSpace"])
  ],
  targets: [
    .executableTarget(name: "FreeSpace"),
    .testTarget(name: "FreeSpaceTests", dependencies: ["FreeSpace"]),
  ]
)
