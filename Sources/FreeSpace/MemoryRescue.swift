import AppKit
import Darwin
import Foundation

enum MemoryPressureLevel: String, Codable, Equatable, Sendable {
  case normal
  case warning
  case critical
  case unknown

  init(nativeValue: Int32) {
    if nativeValue & 4 != 0 {
      self = .critical
    } else if nativeValue & 2 != 0 {
      self = .warning
    } else if nativeValue & 1 != 0 {
      self = .normal
    } else {
      self = .unknown
    }
  }

  var title: String {
    switch self {
    case .normal:
      "Normal"
    case .warning:
      "Warning"
    case .critical:
      "Critical"
    case .unknown:
      "Checking"
    }
  }
}

struct ProcessMemoryTreeInput: Sendable {
  let rootProcessID: Int32
  let childrenByParent: [Int32: [Int32]]
  let footprintByProcess: [Int32: UInt64]
}

enum ProcessMemoryTree {
  static func total(_ input: ProcessMemoryTreeInput) -> UInt64 {
    var pending = [input.rootProcessID]
    var visited: Set<Int32> = []
    var total: UInt64 = 0

    while let processID = pending.popLast() {
      guard visited.insert(processID).inserted else {
        continue
      }

      total += input.footprintByProcess[processID, default: 0]
      pending.append(contentsOf: input.childrenByParent[processID, default: []])
    }

    return total
  }
}

struct MemoryAppProtectionInput: Sendable {
  let processID: Int32
  let bundleIdentifier: String?
  let bundlePath: String
  let currentProcessID: Int32
  let currentBundleIdentifier: String?
}

enum MemoryAppProtection {
  static func reason(_ input: MemoryAppProtectionInput) -> String? {
    if input.processID == input.currentProcessID
      || (input.currentBundleIdentifier != nil
        && input.bundleIdentifier == input.currentBundleIdentifier)
    {
      return "\(AppBrand.name) stays running during rescue"
    }

    if input.bundleIdentifier == "com.apple.finder"
      || input.bundlePath.hasPrefix("/System/Library/")
      || input.bundlePath.hasPrefix("/System/Applications/")
    {
      return "macOS system app"
    }

    let identifier = input.bundleIdentifier?.lowercased() ?? ""
    let appName = URL(fileURLWithPath: input.bundlePath).deletingPathExtension().lastPathComponent
      .lowercased()
    if ["chatgpt", "claude", "codex", "cursor", "windsurf"].contains(where: {
      identifier.contains($0) || appName.contains($0)
    }) {
      return "AI app and its workers stay running"
    }
    if ["terminal", "iterm", "cmux", "warp", "ghostty", "wezterm", "alacritty", "kitty"].contains(
      where: {
        identifier.contains($0) || appName.contains($0)
      })
    {
      return "Terminal sessions may contain running work"
    }
    return nil
  }
}

struct MemoryAppDescriptor: Sendable {
  let processID: Int32
  let name: String
  let bundleIdentifier: String?
  let bundleURL: URL
  let protectionReason: String?
  let isActive: Bool
  let launchDate: Date?
}

struct MemoryApp: Equatable, Identifiable, Sendable {
  let processID: Int32
  let name: String
  let bundleIdentifier: String?
  let bundleURL: URL
  let memoryBytes: UInt64
  let protectionReason: String?
  let isActive: Bool
  let launchDate: Date?
  let childProcessCount: Int

  var policyKey: String { bundleIdentifier ?? bundleURL.path }

  var id: Int32 {
    processID
  }
}

struct MemoryPressureReader: Sendable {
  func current() -> MemoryPressureLevel {
    var nativeValue: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let result = sysctlbyname(
      "kern.memorystatus_vm_pressure_level",
      &nativeValue,
      &size,
      nil,
      0
    )

    guard result == 0 else {
      return .unknown
    }

    return MemoryPressureLevel(nativeValue: nativeValue)
  }
}

@MainActor
struct MemoryAppProvider {
  func descriptors() -> [MemoryAppDescriptor] {
    let currentProcessID = ProcessInfo.processInfo.processIdentifier
    let currentBundleIdentifier = Bundle.main.bundleIdentifier

    return NSWorkspace.shared.runningApplications.compactMap { application in
      guard !application.isTerminated,
        application.activationPolicy != .prohibited,
        let name = application.localizedName,
        let bundleURL = application.bundleURL
      else {
        return nil
      }

      let bundleIdentifier = application.bundleIdentifier
      let protectionReason = MemoryAppProtection.reason(
        MemoryAppProtectionInput(
          processID: application.processIdentifier,
          bundleIdentifier: bundleIdentifier,
          bundlePath: bundleURL.path,
          currentProcessID: currentProcessID,
          currentBundleIdentifier: currentBundleIdentifier
        )
      )

      return MemoryAppDescriptor(
        processID: application.processIdentifier,
        name: name,
        bundleIdentifier: bundleIdentifier,
        bundleURL: bundleURL,
        protectionReason: protectionReason,
        isActive: application.isActive,
        launchDate: application.launchDate
      )
    }
  }
}

struct NativeProcessMemoryScanner: Sendable {
  func scan(_ descriptors: [MemoryAppDescriptor]) -> [MemoryApp] {
    let snapshot = processSnapshot()

    let rootIDs = Set(descriptors.map(\.processID))
    let parents = snapshot.childrenByParent.reduce(into: [Int32: Int32]()) { result, pair in
      for child in pair.value { result[child] = pair.key }
    }
    return descriptors.compactMap { descriptor in
      var ancestor = parents[descriptor.processID]
      var ancestors: Set<Int32> = [descriptor.processID]
      while let parent = ancestor, ancestors.insert(parent).inserted {
        if rootIDs.contains(parent) { return nil }
        ancestor = parents[parent]
      }
      var descendants: Set<Int32> = []
      var pending = snapshot.childrenByParent[descriptor.processID, default: []]
      while let child = pending.popLast() {
        guard descendants.insert(child).inserted else { continue }
        pending.append(contentsOf: snapshot.childrenByParent[child, default: []])
      }
      let memoryBytes = ProcessMemoryTree.total(
        ProcessMemoryTreeInput(
          rootProcessID: descriptor.processID,
          childrenByParent: snapshot.childrenByParent,
          footprintByProcess: snapshot.footprintByProcess
        )
      )

      guard memoryBytes > 0 else {
        return nil
      }

      return MemoryApp(
        processID: descriptor.processID,
        name: descriptor.name,
        bundleIdentifier: descriptor.bundleIdentifier,
        bundleURL: descriptor.bundleURL,
        memoryBytes: memoryBytes,
        protectionReason: descriptor.protectionReason,
        isActive: descriptor.isActive,
        launchDate: descriptor.launchDate,
        childProcessCount: descendants.count
      )
    }
    .sorted { left, right in
      left.memoryBytes > right.memoryBytes
    }
  }

  private func processSnapshot() -> NativeProcessMemorySnapshot {
    var childrenByParent: [Int32: [Int32]] = [:]
    var footprintByProcess: [Int32: UInt64] = [:]

    for processID in processIDs() {
      if let parentProcessID = parentProcessID(processID) {
        childrenByParent[parentProcessID, default: []].append(processID)
      }

      if let footprint = footprint(processID) {
        footprintByProcess[processID] = footprint
      }
    }

    return NativeProcessMemorySnapshot(
      childrenByParent: childrenByParent,
      footprintByProcess: footprintByProcess
    )
  }

  private func processIDs() -> [Int32] {
    let estimate = max(64, Int(proc_listallpids(nil, 0)) + 64)
    var processIDs = [Int32](repeating: 0, count: estimate)
    let count = processIDs.withUnsafeMutableBytes { buffer in
      proc_listallpids(buffer.baseAddress, Int32(buffer.count))
    }

    guard count > 0 else {
      return []
    }

    return Array(processIDs.prefix(Int(count))).filter { processID in
      processID > 0
    }
  }

  private func parentProcessID(_ processID: Int32) -> Int32? {
    var info = proc_bsdinfo()
    let expectedSize = MemoryLayout<proc_bsdinfo>.size
    let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(
        processID,
        PROC_PIDTBSDINFO,
        0,
        pointer,
        Int32(expectedSize)
      )
    }

    guard actualSize == expectedSize else {
      return nil
    }

    return Int32(info.pbi_ppid)
  }

  private func footprint(_ processID: Int32) -> UInt64? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      proc_pid_rusage(
        processID,
        RUSAGE_INFO_V4,
        UnsafeMutableRawPointer(pointer)
          .assumingMemoryBound(to: Optional<UnsafeMutableRawPointer>.self)
      )
    }

    guard result == 0 else {
      return nil
    }

    return usage.ri_phys_footprint
  }
}

private struct NativeProcessMemorySnapshot: Sendable {
  let childrenByParent: [Int32: [Int32]]
  let footprintByProcess: [Int32: UInt64]
}
