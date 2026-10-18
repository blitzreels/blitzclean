import Darwin
import Foundation

struct LiveProcessTree: Sendable {
  let parents: [Int32: Int32]

  static func read() -> Self {
    let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 256)
    var ids = [Int32](repeating: 0, count: capacity)
    let count = ids.withUnsafeMutableBytes {
      proc_listallpids($0.baseAddress, Int32($0.count))
    }
    var parents: [Int32: Int32] = [:]
    for pid in ids.prefix(max(0, min(Int(count), capacity))) where pid > 1 {
      var info = proc_bsdinfo()
      let size = MemoryLayout<proc_bsdinfo>.stride
      let read = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
      }
      if read == size, info.pbi_uid == getuid(), info.pbi_status != SZOMB {
        parents[pid] = Int32(info.pbi_ppid)
      }
    }
    return Self(parents: parents)
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
      for pid in ordered {
        guard let expected = tracked[pid], let current = DevProcessIdentity.read(pid),
          expected.matches(current), pid > 1, pid != getpid(), current.process.owner == getuid()
        else { continue }
        if !signaled.contains(pid), kill(pid, request.signal.value) == 0 {
          signaled.insert(pid)
          if request.signal == .quit, current.process.stopped,
            let latest = DevProcessIdentity.read(pid), expected.matches(latest)
          {
            _ = kill(pid, SIGCONT)
          }
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
