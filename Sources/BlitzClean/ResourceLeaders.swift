import SwiftUI

/// An app or process group that led CPU or RAM use during a history range.
struct ResourceLeader: Identifiable, Equatable {
  let name: String
  let peak: Double
  let peakAt: Date
  /// Whole-Mac CPU or RAM ratio at the moment of the peak.
  let systemAtPeak: Double?
  /// Approximate time this group was the top user; archived points cover five minutes each.
  let leadDuration: TimeInterval
  var id: String { name }
}

enum ResourceLeaders {
  struct Input {
    let samples: [ResourceSample]
    let kind: ResourceKind
    let seconds: TimeInterval
  }

  static func rank(_ input: Input) -> [ResourceLeader] {
    let cutoff = (input.samples.last?.date ?? .now).addingTimeInterval(-input.seconds)
    let visible = input.samples.filter { $0.date >= cutoff }
    var leaders: [String: ResourceLeader] = [:]
    for (index, sample) in visible.enumerated() {
      guard let lead = input.kind == .cpu ? sample.cpuLead : sample.memoryLead else { continue }
      let next =
        index + 1 < visible.count ? visible[index + 1].date : sample.date.addingTimeInterval(2)
      let span = min(max(0, next.timeIntervalSince(sample.date)), 300)
      let system = input.kind.value(sample)
      let previous = leaders[lead.name]
      let isPeak = previous.map { lead.value > $0.peak } ?? true
      leaders[lead.name] = ResourceLeader(
        name: lead.name,
        peak: isPeak ? lead.value : previous?.peak ?? lead.value,
        peakAt: isPeak ? sample.date : previous?.peakAt ?? sample.date,
        systemAtPeak: isPeak ? system : previous?.systemAtPeak,
        leadDuration: (previous?.leadDuration ?? 0) + span)
    }
    return leaders.values.sorted {
      $0.peak == $1.peak ? $0.name < $1.name : $0.peak > $1.peak
    }
  }
}

/// Names what caused the spikes in the chart above it.
struct ResourceLeadersSection: View {
  let samples: [ResourceSample]
  let kind: ResourceKind
  let seconds: TimeInterval
  let limit: Int
  /// What to offer for a leader that is still running; nil when it exited or cannot be acted on.
  let action: (ResourceLeader) -> ResourceVerdict.Action?

  var body: some View {
    let leaders = ResourceLeaders.rank(.init(samples: samples, kind: kind, seconds: seconds))
    VStack(alignment: .leading, spacing: 10) {
      BlitzSectionHeader(
        title: kind == .cpu ? "Biggest CPU spikes" : "Biggest memory users", count: nil
      ) {}
      LazyVStack(spacing: 0) {
        if leaders.isEmpty {
          BlitzEmptyRow(text: "Recording which apps use the most \(noun)…", isLoading: false)
        }
        let visible = Array(leaders.prefix(limit))
        ForEach(visible) { leader in
          row(leader)
          if leader.id != visible.last?.id { BlitzRowDivider(leading: 56) }
        }
      }.blitzTable()
      Text(caption).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
    }
  }

  private var noun: String { kind == .cpu ? "CPU" : "memory" }

  private var caption: String {
    kind == .cpu
      ? "Helpers count toward their app. 100% equals one core. Pick a range above to look further back."
      : "Helpers count toward their app. Pick a range above to look further back."
  }

  private func row(_ leader: ResourceLeader) -> some View {
    HStack(spacing: 12) {
      ApplicationIcon(source: .name(leader.name), size: 28, fallback: "terminal")
      VStack(alignment: .leading, spacing: 2) {
        Text(leader.name).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
        Text(detail(leader)).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1)
      }
      Spacer(minLength: 12)
      BlitzTrailingValue(value: value(leader.peak), detail: "peak")
      if let action = action(leader) {
        Button(action.title, action: action.perform).blitzButton(.secondary)
          .frame(width: 96, alignment: .trailing)
      }
    }.blitzRow()
  }

  private func value(_ peak: Double) -> String {
    kind == .cpu
      ? peak.formatted(.number.precision(.fractionLength(0))) + "%"
      : ByteText.compact(UInt64(max(0, peak)))
  }

  private func detail(_ leader: ResourceLeader) -> String {
    let when =
      Calendar.current.isDateInToday(leader.peakAt)
      ? leader.peakAt.formatted(date: .omitted, time: .shortened)
      : leader.peakAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    let mac = leader.systemAtPeak.map { " · Mac at \(PercentText.make($0))" } ?? ""
    return "Top user for \(Self.duration(leader.leadDuration)) · peak \(when)\(mac)"
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    formatter.allowedUnits = seconds < 60 ? [.second] : [.day, .hour, .minute]
    return formatter.string(from: max(1, seconds)) ?? "—"
  }
}
