import Darwin
import Foundation

struct DependencyFootprint: Equatable, Sendable {
  let allocated: UInt64
  let content: UInt64
}

enum DependencyFileScan {
  struct DiscoveryRequest {
    let root: String
    let deadline: Date
    let maximumEntries: Int
  }

  struct Discovery {
    let paths: [String]
    let complete: Bool
  }

  static func discoverWithin(_ request: DiscoveryRequest) -> Discovery {
    guard let tree = FileTree(.init(path: request.root, needsMetadata: false)) else {
      return .init(paths: [], complete: false)
    }
    var paths: [String] = []
    var visited = 0
    var complete = true
    while let entry = tree.next() {
      visited += 1
      guard visited <= request.maximumEntries, Date.now < request.deadline else {
        complete = false
        break
      }
      if [.unreadable, .unreadableDirectory].contains(entry.kind) { complete = false }
      guard entry.kind == .directory else { continue }
      let name = entry.name
      if name == "node_modules" {
        paths.append(entry.path)
        tree.skip(entry)
      } else if entry.level > 0,
        generatedDirectories.contains(name)
          || [".Trashes", ".Spotlight-V100", ".fseventsd", "Backups.backupdb"].contains(name)
      {
        tree.skip(entry)
      }
    }
    return .init(paths: paths, complete: complete)
  }

  static func discover(_ roots: [String]) -> [String] {
    var uniqueRoots: [String] = []
    for root in Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).sorted() {
      if !uniqueRoots.contains(where: { root.hasPrefix($0 + "/") }) { uniqueRoots.append(root) }
    }
    let roots = uniqueRoots
    let output = DiscoveredPaths()
    DispatchQueue.concurrentPerform(iterations: min(2, roots.count)) { worker in
      for index in stride(from: worker, to: roots.count, by: 2) {
        guard let tree = FileTree(.init(path: roots[index], needsMetadata: false)) else {
          continue
        }
        while let entry = tree.next() {
          guard entry.kind == .directory else { continue }
          let name = entry.name
          if name == "node_modules" {
            output.insert(entry.path)
            tree.skip(entry)
          } else if entry.level > 0, generatedDirectories.contains(name) {
            tree.skip(entry)
          }
        }
      }
    }
    return output.values
  }

  static func measure(_ path: String) -> DependencyFootprint? {
    measure(.init(path: path, deadline: .distantFuture))
  }

  struct Measurement {
    let path: String
    let deadline: Date
  }

  /// Nil unless every entry was read: a dependency size decides what gets deleted.
  static func measure(_ request: Measurement) -> DependencyFootprint? {
    guard
      let footprint = FolderFootprint.measure(
        .init(path: request.path, deadline: request.deadline)),
      !footprint.partial
    else { return nil }
    return .init(allocated: footprint.allocated, content: footprint.content)
  }

  static func measureAll(_ paths: [String]) -> [String: DependencyFootprint] {
    measureAll(.init(paths: paths, measure: measure))
  }

  struct MeasurementRequest {
    let paths: [String]
    let measure: @Sendable (String) -> DependencyFootprint?
  }

  static func measureAll(_ request: MeasurementRequest) -> [String: DependencyFootprint] {
    let paths = Array(Set(request.paths)).sorted()
    let output = Measurements(paths: paths)
    let workers = min(4, paths.count)
    guard workers > 0 else { return [:] }
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
      while let path = output.next() {
        if let footprint = request.measure(path) {
          output.record(.init(path: path, footprint: footprint))
        }
      }
    }
    return output.values
  }

  private static let generatedDirectories: Set<String> = [
    ".git", ".build", ".venv", "venv", "__pycache__", "Pods", ".gradle",
  ]

  private final class DiscoveredPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func insert(_ path: String) {
      lock.lock()
      defer { lock.unlock() }
      paths.insert(path)
    }

    var values: [String] {
      lock.lock()
      defer { lock.unlock() }
      return paths.sorted()
    }
  }

  private final class Measurements: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: DependencyFootprint] = [:]
    private let paths: [String]
    private var index = 0

    init(paths: [String]) { self.paths = paths }

    func next() -> String? {
      lock.lock()
      defer { lock.unlock() }
      guard index < paths.count else { return nil }
      defer { index += 1 }
      return paths[index]
    }

    struct Entry {
      let path: String
      let footprint: DependencyFootprint
    }

    func record(_ entry: Entry) {
      lock.lock()
      defer { lock.unlock() }
      storage[entry.path] = entry.footprint
    }

    var values: [String: DependencyFootprint] {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
  }
}
