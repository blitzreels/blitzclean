import Darwin
import Foundation

struct LiveProcessTree: Sendable {
  let parents: [Int32: Int32]

  static func read() -> Self {
    Self(
      parents: Dictionary(
        NativeProcessList.rows(.init(owner: getuid())).map { ($0.pid, $0.parent) },
        uniquingKeysWith: { first, _ in first }))
  }

  func descendants(_ roots: Set<Int32>) -> [Int32] {
    let children = Dictionary(grouping: parents.keys, by: { parents[$0] ?? 0 })
    var pending = Array(roots).sorted()
    var seen: Set<Int32> = []
    var result: [Int32] = []
    var index = 0
    while index < pending.count {
      let pid = pending[index]
      index += 1
      guard seen.insert(pid).inserted else { continue }
      result.append(pid)
      pending.append(contentsOf: children[pid, default: []].sorted())
    }
    return result
  }
}

enum WorkloadControl {
  struct Request: Sendable {
    let identities: [DevProcessIdentity]
    let signal: AIThreadSignal
  }

  struct Result: Sendable {
    let affected: Int
    let remaining: Int
    let retainedBytes: UInt64
    let identities: [DevProcessIdentity]

    var completed: Bool { affected > 0 && remaining == 0 }
  }

  static func execute(_ request: Request) async -> Result {
    var tracked = Dictionary(
      request.identities.map { ($0.process.processID, $0) }, uniquingKeysWith: { a, _ in a })
    var signaled: Set<Int32> = []
    var remaining = 0
    for attempt in 0..<12 {
      let live = tracked.compactMapValues { expected -> DevProcessIdentity? in
        guard let current = DevProcessIdentity.read(expected.process.processID),
          expected.matches(current), current.process.owner == getuid(),
          current.process.processID > 1, current.process.processID != getpid()
        else { return nil }
        return current
      }
      let tree = LiveProcessTree.read()
      let roots = Set(live.keys.filter { live[tree.parents[$0] ?? 0] == nil })
      let ordered = tree.descendants(roots)
      for pid in ordered where tracked[pid] == nil && pid != getpid() {
        guard let parent = tree.parents[pid], let expectedParent = tracked[parent],
          let currentParent = DevProcessIdentity.read(parent),
          expectedParent.matches(currentParent),
          let child = DevProcessIdentity.read(pid), child.process.owner == getuid()
        else { continue }
        tracked[pid] = child
      }
      for pid in ordered where !signaled.contains(pid) {
        guard let expected = tracked[pid] else { continue }
        if ProcessSignal.send(.init(expected: expected, signal: request.signal.value)).wasSent {
          signaled.insert(pid)
        }
      }
      remaining =
        tracked.values.filter { expected in
          guard let current = DevProcessIdentity.read(expected.process.processID) else {
            return false
          }
          guard expected.matches(current) else { return true }
          switch request.signal {
          case .pause: return !current.process.stopped
          case .resume: return current.process.stopped
          case .quit, .forceQuit: return true
          }
        }.count
      if remaining == 0, attempt > 0 { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    let survivors = tracked.values.compactMap { expected -> DevProcessIdentity? in
      guard let current = DevProcessIdentity.read(expected.process.processID),
        expected.matches(current)
      else { return nil }
      return current
    }
    return Result(
      affected: signaled.count, remaining: remaining,
      retainedBytes: survivors.reduce(0) {
        $0 + (ProcessFootprint.bytes($1.process.processID) ?? 0)
      },
      identities: Array(tracked.values))
  }
}
