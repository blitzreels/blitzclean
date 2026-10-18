import Foundation
import Testing

@testable import BlitzClean

struct RemovalGateTests {
  @Test
  func removesTheReviewedItem() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let file = root + "/cache.bin"
    try Data("x".utf8).write(to: URL(fileURLWithPath: file))
    try RemovalGate.remove(
      .init(path: file, expected: FileIdentity.read(file), method: .permanent))
    #expect(!FileManager.default.fileExists(atPath: file))
  }

  @Test
  func keepsItemsReplacedSinceReview() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let file = root + "/cache.bin"
    try Data("x".utf8).write(to: URL(fileURLWithPath: file))
    let reviewed = try #require(FileIdentity.read(file))
    try FileManager.default.removeItem(atPath: file)
    try Data("new".utf8).write(to: URL(fileURLWithPath: file))
    let current = try #require(FileIdentity.read(file))
    try #require(current != reviewed)
    #expect(throws: RemovalGate.Refusal.changed) {
      try RemovalGate.remove(.init(path: file, expected: reviewed, method: .permanent))
    }
    #expect(FileManager.default.fileExists(atPath: file))
  }

  @Test
  func keepsItemsBehindLinkedFolders() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(
      atPath: root + "/real", withIntermediateDirectories: true)
    try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/real/file"))
    try FileManager.default.createSymbolicLink(
      atPath: root + "/link", withDestinationPath: root + "/real")
    #expect(throws: RemovalGate.Refusal.linkedParent) {
      try RemovalGate.remove(.init(path: root + "/link/file", expected: nil, method: .permanent))
    }
    #expect(FileManager.default.fileExists(atPath: root + "/real/file"))
  }

  @Test
  func refusesPathsThatAreNotNormalized() {
    for path in ["relative/file", "/tmp/a/../b", "/Users/someone/dev/", "/"] {
      #expect(throws: RemovalGate.Refusal.self) {
        try RemovalGate.check(.init(path: path, expected: nil, method: .permanent))
      }
    }
  }

  @Test
  func protectsHomeSystemAndGitRoots() {
    let home = NSHomeDirectory()
    let protected = [
      home, home + "/Documents", home + "/Library", home + "/Library/Caches", home + "/dev",
      "/Applications", "/System", "/private/tmp", "/Users", home + "/dev/app/.git",
      home + "/dev/app/.git/objects/pack/big.pack",
    ]
    for path in protected {
      #expect(RemovalGate.protection(path) != nil, "\(path) should be protected")
    }
    let removable = [
      home + "/Library/Caches/com.example.app", home + "/dev/app/node_modules",
      home + "/Downloads/installer.dmg", "/private/tmp/build-output", "/Applications/Old.app",
    ]
    for path in removable {
      #expect(RemovalGate.protection(path) == nil, "\(path) should be removable")
    }
  }

  @Test
  func eligibilityChecksHonorTheGate() {
    let home = NSHomeDirectory()
    #expect(!ReviewFileDeletion.canDeleteWhenChosen(home + "/dev"))
    #expect(!ReviewFileDeletion.canTrashPath(home + "/dev/app/.git/objects/pack/big.pack"))
  }

  private func temporaryRoot() throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("removal-gate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try #require(ReviewFile.canonicalPath(url.path))
  }
}
