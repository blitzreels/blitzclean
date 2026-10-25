import Darwin
import Foundation

/// The one way BlitzClean lists processes: a native read of the kernel's table, with no `ps` to start.
/// The brake, the project scan and process trees all read it, so every feature sees the same processes.
enum NativeProcessList {
  struct Row: Equatable, Sendable {
    let pid: Int32
    let parent: Int32
    let uid: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let state: UInt32
    /// The kernel's short name, which changes on exec while the PID and start time stay.
    let command: String
    let terminal: UInt32

    var start: UInt64 { startSeconds &* 1_000_000 &+ startMicroseconds }
  }

  struct Filter {
    /// Only this user's processes; nil reads everyone's.
    let owner: uid_t?
  }

  static func rows(_ filter: Filter) -> [Row] {
    let capacity = max(1_024, Int(proc_listallpids(nil, 0)) + 256)
    var ids = [Int32](repeating: 0, count: capacity)
    let count = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    return ids.prefix(max(0, min(Int(count), capacity))).compactMap { pid in
      guard pid > 1 else { return nil }
      var info = proc_bsdinfo()
      let size = MemoryLayout<proc_bsdinfo>.stride
      let read = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
      }
      guard read == size, info.pbi_status != SZOMB,
        filter.owner.map({ info.pbi_uid == $0 }) ?? true
      else { return nil }
      let command = withUnsafeBytes(of: info.pbi_name) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      }
      return Row(
        pid: pid, parent: Int32(info.pbi_ppid), uid: info.pbi_uid,
        startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
        state: info.pbi_status, command: command, terminal: info.e_tdev)
    }
  }
}

enum ProcessArguments {
  /// Arguments as `ps` shows them, including titles a program sets for itself. Most fit in 16 KB, so
  /// only a few processes pay for the larger buffer.
  static func read(_ processID: Int32) -> [String] {
    for size in [16_384, 1_024 * 1_024] {
      var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
      var length = size
      var data = Data(count: size)
      let result = data.withUnsafeMutableBytes { buffer in
        sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &length, nil, 0)
      }
      if result == 0, length > MemoryLayout<Int32>.size {
        return AIThreadNames.arguments(Data(data.prefix(length)))
      }
      if errno != ENOMEM && errno != EINVAL { return [] }
    }
    return []
  }
}

/// Builds the rows `ps -axo pid,ppid,uid,pcpu,rss,etime,tty,args` printed, without starting `ps`.
/// CPU is the share used since the previous read, so the first read reports 0.
final class NativeProcessRecords: @unchecked Sendable {
  static let shared = NativeProcessRecords()

  private struct Key: Hashable {
    let pid: Int32
    let start: UInt64
  }

  private let lock = NSLock()
  private var previous: [Key: UInt64] = [:]
  private var previousDate: Date?
  private var arguments: [Key: String] = [:]
  /// `devname` looks the device up in /dev on every call; a Mac has a handful of terminals.
  private var terminals: [UInt32: String?] = [:]
  private let nanosecondsPerTick = CPUProcessReader.nanosecondsPerTick ?? 1

  func read() -> [RawProcessRecord] {
    lock.lock()
    defer { lock.unlock() }
    let now = Date.now
    let seconds = previousDate.map { now.timeIntervalSince($0) } ?? 0
    var ticks: [Key: UInt64] = [:]
    var names: [Key: String] = [:]
    let records = NativeProcessList.rows(.init(owner: getuid())).compactMap {
      row -> RawProcessRecord? in
      let key = Key(pid: row.pid, start: row.start)
      var usage = rusage_info_v4()
      let status = withUnsafeMutablePointer(to: &usage) {
        proc_pid_rusage(
          row.pid, RUSAGE_INFO_V4,
          UnsafeMutableRawPointer($0).assumingMemoryBound(
            to: Optional<UnsafeMutableRawPointer>.self))
      }
      guard status == 0 else { return nil }
      let used = usage.ri_user_time &+ usage.ri_system_time
      ticks[key] = used
      var cpu = 0.0
      if seconds > 0, let old = previous[key], used >= old {
        cpu = Double(used - old) * nanosecondsPerTick / (seconds * 1_000_000_000) * 100
      }
      let age = now.timeIntervalSince1970 - Double(row.startSeconds)
      let argumentLine =
        arguments[key]
        ?? {
          let read = ProcessArguments.read(row.pid).joined(separator: " ")
          return read.isEmpty ? row.command : read
        }()
      if age >= 30 { names[key] = argumentLine }
      return RawProcessRecord(
        processID: row.pid, parentProcessID: row.parent, userID: Int(row.uid),
        cpuPercent: (cpu * 10).rounded() / 10, residentKilobytes: usage.ri_resident_size / 1_024,
        elapsed: Self.elapsed(max(0, age)), terminal: terminal(row.terminal),
        arguments: argumentLine)
    }
    previous = ticks
    previousDate = now
    if terminals.count > 256 { terminals.removeAll() }
    arguments = names
    return records
  }

  /// `ps` etime: `[[dd-]hh:]mm:ss`.
  static func elapsed(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let days = total / 86_400
    let hours = total / 3_600 % 24
    let minutes = total / 60 % 60
    let rest = total % 60
    let clock = String(format: "%02d:%02d", minutes, rest)
    if days > 0 { return String(format: "%d-%02d:", days, hours) + clock }
    if hours > 0 { return String(format: "%02d:", hours) + clock }
    return clock
  }

  private func terminal(_ device: UInt32) -> String? {
    if let known = terminals[device] { return known }
    let name = Self.terminal(device)
    terminals[device] = .some(name)
    return name
  }

  /// `ps` tty: `ttys003`, or nil for a process with no terminal.
  static func terminal(_ device: UInt32) -> String? {
    guard device != UInt32(bitPattern: -1), device != 0,
      let name = devname(dev_t(bitPattern: device), S_IFCHR)
    else { return nil }
    return String(cString: name)
  }
}
