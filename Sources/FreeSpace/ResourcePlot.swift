import Charts
import SwiftUI

enum ResourceKind { case memory, cpu }

struct ResourcePlot: View {
  let samples: [ResourceSample]
  let kind: ResourceKind
  let color: Color
  let seconds: TimeInterval

  private var visibleSamples: [ResourceSample] {
    let end = samples.last?.date ?? .now
    return samples.filter { $0.date >= end.addingTimeInterval(-seconds) }
  }

  var body: some View {
    Chart(visibleSamples) { sample in
      if let value = kind == .cpu ? sample.cpu : sample.memory {
        AreaMark(x: .value("Time", sample.date), y: .value("Usage", value))
          .foregroundStyle(
            LinearGradient(
              colors: [color.opacity(0.25), color.opacity(0.015)], startPoint: .top,
              endPoint: .bottom))
        LineMark(x: .value("Time", sample.date), y: .value("Usage", value))
          .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
      }
    }
    .chartYScale(domain: 0...1)
    .chartXScale(
      domain: (samples.last?.date ?? .now).addingTimeInterval(
        -seconds)...(samples.last?.date ?? .now)
    )
    .chartXAxis(.hidden).chartYAxis(.hidden)
    .accessibilityLabel(kind == .cpu ? "CPU usage history" : "RAM usage history")
  }
}

struct HistoryRangePicker: View {
  @Binding var seconds: Double
  var body: some View {
    BlitzSegmentedPicker(
      title: "History", options: [60.0, 300.0, 900.0], selection: $seconds,
      label: { "\(Int($0 / 60))m" }
    ).frame(width: 150).controlSize(.small)
  }
}
