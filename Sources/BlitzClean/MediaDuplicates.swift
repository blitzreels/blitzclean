import CryptoKit
import Darwin
import Foundation

struct MediaDuplicateGroup: Identifiable, Sendable {
  let digest: String
  let files: [ReviewFile]
  var id: String { digest }
}

struct MediaDuplicateResult: Sendable {
  let groups: [MediaDuplicateGroup]
  let skipped: Int
  let limited: Bool
}

enum MediaDuplicateScanner {
  static func scan(_ files: [ReviewFile]) -> MediaDuplicateResult {
    var seen = Set<String>()
    let unique = files.filter {
      $0.logicalBytes > 0 && seen.insert("\($0.device):\($0.inode)").inserted
        && ["Video", "Image"].contains($0.kind)
    }
    let candidates = Dictionary(grouping: unique, by: \.logicalBytes).values
      .filter { $0.count > 1 }.sorted {
        ($0.first?.logicalBytes ?? 0) < ($1.first?.logicalBytes ?? 0)
      }
    let deadline = Date.now.addingTimeInterval(120)
    var groups: [MediaDuplicateGroup] = []
    var skipped = 0
    var limited = false
    for bucket in candidates {
      if Task.isCancelled || Date.now > deadline {
        limited = true
        break
      }
      var byHash: [String: [ReviewFile]] = [:]
      for file in bucket {
        if Task.isCancelled || Date.now > deadline {
          limited = true
          break
        }
        do {
          let value = try digest(.init(file: file, deadline: deadline))
          byHash[value, default: []].append(file)
        } catch { skipped += 1 }
      }
      groups += byHash.filter { $0.value.count > 1 }.map {
        MediaDuplicateGroup(digest: $0.key, files: $0.value.sorted { $0.path < $1.path })
      }
    }
    return .init(
      groups: groups.sorted { $0.id < $1.id }, skipped: skipped,
      limited: limited || Task.isCancelled || Date.now > deadline)
  }

  struct DigestRequest {
    let file: ReviewFile
    let deadline: Date
  }

  static func digest(_ request: DigestRequest) throws -> String {
    let file = request.file
    guard file.currentVersion.map(file.matchesIdentity) == true else {
      throw ReviewDeleteError.changed
    }
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ReviewDeleteError.unverified }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_dev == file.device, info.st_ino == file.inode,
      info.st_mode & S_IFMT == S_IFREG
    else { throw ReviewDeleteError.changed }
    var hasher = SHA256()
    while true {
      try Task.checkCancellation()
      guard Date.now < request.deadline else { throw CocoaError(.userCancelled) }
      let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    guard file.currentVersion.map(file.matchesIdentity) == true else {
      throw ReviewDeleteError.changed
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
