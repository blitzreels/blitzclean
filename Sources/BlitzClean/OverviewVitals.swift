import SwiftUI

/// Memory, CPU and disk at a glance above the problem cards; each tile opens its page.
struct OverviewVitals: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var navigation: CleanNavigation

  private struct Vital: Identifiable {
    let page: CleanPage
    let fraction: Double
    let tone: BlitzStatusTone
    let caption: String
    let trend: [Double]?
    var id: CleanPage { page }
  }

  private var vitals: [Vital] {
    let snapshot = monitor.snapshot
    let recent = Self.recent(monitor.resourceSamples)
    var result = [
      Vital(
        page: .memory, fraction: snapshot.ramUsedRatio, tone: memory.pressure.tone,
        caption: "\(ByteText.compact(snapshot.ramAvailable)) free",
        trend: recent.map(\.memory))
    ]
    if let cpu = snapshot.cpuUsage {
      result.append(
        .init(
          page: .cpu, fraction: cpu, tone: MenuBarTones.cpu(cpu),
          caption: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
          trend: recent.compactMap(\.cpu)))
    }
    if snapshot.diskTotal > 0 {
      result.append(
        .init(
          page: .storage, fraction: snapshot.diskUsedRatio,
          tone: MenuBarTones.disk(snapshot),
          caption: "\(ByteText.compact(snapshot.diskAvailable)) free of "
            + ByteText.compact(snapshot.diskTotal), trend: nil))
    }
    return result
  }

  var body: some View {
    HStack(spacing: 12) {
      ForEach(vitals) { vital in
        Button {
          if vital.page == .storage { navigation.storagePage = .drive }
          navigation.page = vital.page
        } label: {
          tile(vital)
        }
        .buttonStyle(BlitzCardButtonStyle())
        .help("Open \(vital.page.rawValue)")
      }
    }
  }

  private func tile(_ vital: Vital) -> some View {
    HStack(spacing: 14) {
      BlitzRingGauge(fraction: vital.fraction, tone: vital.tone, size: 54, lineWidth: 6) {
        Text(PercentText.make(vital.fraction)).font(BlitzNumberFont.value(13)).monospacedDigit()
          .contentTransition(.numericText())
          .animation(.snappy, value: vital.fraction)
      }
      VStack(alignment: .leading, spacing: 6) {
        VStack(alignment: .leading, spacing: 1) {
          Text(vital.page == .storage ? "Disk" : vital.page.rawValue).font(BlitzType.rowTitle)
          Text(vital.caption).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            .monospacedDigit().lineLimit(1).contentTransition(.numericText())
        }
        if let trend = vital.trend, trend.count > 1 {
          BlitzSparkline(values: BlitzSparkline.thinned(trend, to: 60), tone: vital.tone)
            .frame(height: 22)
        } else {
          BlitzMeter(fraction: vital.fraction, tone: vital.tone, height: 5)
            .frame(height: 22, alignment: .bottom)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .blitzSurface()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(vital.page.rawValue) \(PercentText.make(vital.fraction)), \(vital.caption)")
  }

  /// The last fifteen minutes, enough to show a trend without the scan cost of the full history.
  private static func recent(_ samples: [ResourceSample]) -> ArraySlice<ResourceSample> {
    guard let last = samples.last?.date else { return [] }
    let cutoff = last.addingTimeInterval(-900)
    let start = samples.lastIndex { $0.date < cutoff }.map { $0 + 1 } ?? samples.startIndex
    return samples[start...]
  }
}
