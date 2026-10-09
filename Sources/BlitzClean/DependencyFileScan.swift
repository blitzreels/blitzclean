import Darwin
import Foundation

struct DependencyFootprint: Equatable, Sendable {
  let allocated: UInt64
  let content: UInt64
}

enum DependencyFileScan {
  static func discover(_ roots: [String]) -> [String] {
    var uniqueRoots: [String] = []
    for root in Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).sorted() {
      if !uniqueRoots.contains(where: { root.hasPrefix($0 + "/") }) { uniqueRoots.append(root) }
    }
    let roots = uniqueRoots
    let output = DiscoveredPaths()
    DispatchQueue.concurrentPerform(iterations: min(2, roots.count)) { worker in
      for index in stride(from: worker, to: roots.count, by: 2) {
        guard let tree = DependencyTree(.init(path: roots[index], needsMetadata: false)) else {
          continue
        }
        while let entry = tree.next() {
          guard entry.pointee.fts_info == FTS_D else { continue }
          let name = tree.name(entry)
          if name == "node_modules" {
            output.insert(String(cString: entry.pointee.fts_path))
            tree.skip(entry)
          } else if entry.pointee.fts_level > 0, generatedDirectories.contains(name) {
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

  static func measure(_ request: Measurement) -> DependencyFootprint? {
    guard Date.now < request.deadline,
      let tree = DependencyTree(.init(path: request.path, needsMetadata: true))
    else { return nil }
    var allocated: UInt64 = 0
    var content: UInt64 = 0
    var entries = 0
    var linked: Set<Identity> = []
    errno = 0
    while let entry = tree.next() {
      entries += 1
      if entries % 128 == 0, Date.now >= request.deadline { return nil }
      let info = entry.pointee
      if info.fts_info == FTS_ERR || info.fts_info == FTS_DNR || info.fts_info == FTS_NS {
        return nil
      }
      if info.fts_info == FTS_DP { continue }
      guard let metadata = info.fts_statp?.pointee else { return nil }
      if metadata.st_nlink > 1, info.fts_info != FTS_D {
        guard linked.insert(.init(device: metadata.st_dev, inode: metadata.st_ino)).inserted else {
          continue
        }
      }
      allocated += UInt64(max(0, metadata.st_blocks)) * 512
      content += UInt64(max(0, metadata.st_size))
      errno = 0
    }
    guard errno == 0, Date.now < request.deadline else { return nil }
    return .init(allocated: allocated, content: content)
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

  private struct Identity: Hashable {
    let device: dev_t
    let inode: ino_t
  }

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

private final class DependencyTree {
  struct Input {
    let path: String
    let needsMetadata: Bool
  }

  private let paths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  private let tree: UnsafeMutablePointer<FTS>

  init?(_ input: Input) {
    paths = .allocate(capacity: 2)
    paths.initialize(to: strdup(input.path))
    paths.advanced(by: 1).initialize(to: nil)
    let options = FTS_PHYSICAL | FTS_NOCHDIR | (input.needsMetadata ? 0 : FTS_NOSTAT)
    guard let tree = fts_open(paths, options, nil) else {
      free(paths.pointee)
      paths.deinitialize(count: 2)
      paths.deallocate()
      return nil
    }
    self.tree = tree
  }

  func next() -> UnsafeMutablePointer<FTSENT>? {
    errno = 0
    return fts_read(tree)
  }

  func skip(_ entry: UnsafeMutablePointer<FTSENT>) { fts_set(tree, entry, FTS_SKIP) }

  func name(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
    withUnsafePointer(to: &entry.pointee.fts_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.fts_namelen) + 1) {
        String(cString: $0)
      }
    }
  }

  deinit {
    fts_close(tree)
    free(paths.pointee)
    paths.deinitialize(count: 2)
    paths.deallocate()
  }
}
