import Darwin
import Foundation

final class FolderMeasurementSession: @unchecked Sendable {
  typealias Measure = @Sendable (String) -> DependencyFootprint?

  private enum Result {
    case measured(DependencyFootprint?)
  }

  private let condition = NSCondition()
  private let measure: Measure
  private var results: [String: Result] = [:]
  private var running: Set<String> = []

  init(measure: @escaping Measure = DependencyFileScan.measure) {
    self.measure = measure
  }

  init(deadline: Date) {
    measure = { DependencyFileScan.measure(.init(path: $0, deadline: deadline)) }
  }

  var incompleteCount: Int {
    condition.lock()
    defer { condition.unlock() }
    return results.values.filter {
      if case .measured(nil) = $0 { return true }
      return false
    }.count
  }

  func footprint(_ path: String) -> DependencyFootprint? {
    condition.lock()
    while true {
      if case .measured(let value) = results[path] {
        condition.unlock()
        return value
      }
      if !running.contains(path), running.count < 4 { break }
      condition.wait()
    }
    running.insert(path)
    condition.unlock()
    let value = measure(path)
    condition.lock()
    results[path] = .measured(value)
    running.remove(path)
    condition.broadcast()
    condition.unlock()
    return value
  }

  func directoryBytes(_ path: String) -> UInt64? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    return footprint(path)?.allocated
  }
}
