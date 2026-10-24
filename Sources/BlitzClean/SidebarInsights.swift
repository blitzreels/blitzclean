import Foundation

/// One caption under a sidebar page: its live value and, when known, what is using it most.
struct SidebarInsight: Equatable {
  let text: String
  let tone: BlitzStatusTone

  var needsAttention: Bool { tone == .warning || tone == .critical }
}

enum SidebarInsights {
  struct Input {
    let snapshot: SystemSnapshot
    let memoryTone: BlitzStatusTone
    /// The most recent sample's top users; absent until process readings finish.
    let leads: ResourceLeads
    let pressure: PressureAssessment
    let recoveryCount: Int
    let projectProcesses: [DevProcess]
    let leftoverCount: Int
  }

  static func make(_ input: Input) -> [CleanPage: SidebarInsight] {
    var result: [CleanPage: SidebarInsight] = [:]
    let snapshot = input.snapshot
    if input.pressure.date != .distantPast {
      result[.overview] =
        input.pressure.risk > .normal && input.pressure.limit != .none
        ? .init(
          text: limitText(input.pressure.limit),
          tone: input.pressure.risk >= .critical ? .critical : .warning)
        : .init(text: "Nothing urgent", tone: .muted)
    }
    if snapshot.ramTotal > 0 {
      result[.memory] = .init(
        text: joined(
          "\(ByteText.compact(snapshot.ramAvailable)) free",
          input.leads.memory.map { short($0.name) }),
        tone: input.memoryTone)
    }
    if let cpu = snapshot.cpuUsage {
      result[.cpu] = .init(
        text: joined(PercentText.make(cpu), input.leads.cpu.map { short($0.name) }),
        tone: MenuBarTones.cpu(cpu))
    }
    if snapshot.diskTotal > 0 {
      result[.storage] = .init(
        text: "\(ByteText.compact(snapshot.diskAvailable)) free", tone: MenuBarTones.disk(snapshot))
    }
    result[.recovery] =
      input.recoveryCount > 0
      ? .init(
        text: "\(input.recoveryCount) not responding", tone: .warning)
      : .init(text: "All responding", tone: .muted)
    if input.leftoverCount > 0 {
      result[.projects] = .init(
        text: "\(input.leftoverCount) \(input.leftoverCount == 1 ? "leftover" : "leftovers")",
        tone: .warning)
    } else {
      let projects = Set(input.projectProcesses.compactMap(\.workingDirectory)).count
      let bytes = input.projectProcesses.reduce(0) { $0 + $1.memoryBytes }
      result[.projects] = .init(
        text: projects == 0
          ? "None running"
          : "\(projects) running · \(ByteText.compact(bytes))",
        tone: .muted)
    }
    return result
  }

  private static func limitText(_ limit: PressureLimit) -> String {
    switch limit {
    case .memory: "Memory is short"
    case .disk: "Disk almost full"
    case .cpu: "CPU is saturated"
    case .none: "Nothing urgent"
    }
  }

  static func latestLeads(_ samples: [ResourceSample]) -> ResourceLeads {
    let recent = samples.suffix(3).reversed()
    return ResourceLeads(
      cpu: recent.lazy.compactMap(\.cpuLead).first,
      memory: recent.lazy.compactMap(\.memoryLead).first)
  }

  private static func joined(_ value: String, _ lead: String?) -> String {
    lead.map { "\(value) · \($0)" } ?? value
  }

  private static func short(_ name: String) -> String {
    let trimmed = name.replacingOccurrences(of: "Google ", with: "")
    return trimmed.count > 18 ? String(trimmed.prefix(17)) + "…" : trimmed
  }
}
