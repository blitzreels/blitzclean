import Charts
import SwiftUI

enum ResourceKind {
  case memory, availableMemory, cpu

  var label: String {
    switch self {
    case .memory: "RAM usage"
    case .availableMemory: "RAM available"
    case .cpu: "CPU usage"
    }
  }

  func value(_ sample: ResourceSample) -> Double? {
    switch self {
    case .memory: sample.memory
    case .availableMemory: max(0, 1 - min(1, sample.memory))
    case .cpu: sample.cpu
    }
  }
}

struct ResourcePlot: View {
  let samples: [ResourceSample]
  let kind: ResourceKind
  let color: Color
  let seconds: TimeInterval

  private var visibleSamples: [ResourceSample] {
    let cutoff = (samples.last?.date ?? .now).addingTimeInterval(-seconds)
    var low = samples.startIndex
    var high = samples.endIndex
    while low < high {
      let mid = (low + high) / 2
      if samples[mid].date < cutoff { low = mid + 1 } else { high = mid }
    }
    let visible = samples[low...]
    guard visible.count > 450 else { return Array(visible) }
    let step = Int(ceil(Double(visible.count) / 450))
    var reduced = stride(from: visible.startIndex, to: visible.endIndex, by: step).map {
      visible[$0]
    }
    if reduced.last?.id != visible.last?.id, let last = visible.last { reduced.append(last) }
    return reduced
  }

  private var end: Date { samples.last?.date ?? .now }
  private var start: Date {
    max(
      end.addingTimeInterval(-seconds), min(samples.first?.date ?? end, end.addingTimeInterval(-20))
    )
  }

  var body: some View {
    Chart(visibleSamples) { sample in
      if let value = kind.value(sample) {
        AreaMark(x: .value("Time", sample.date), y: .value(kind.label, value))
          .foregroundStyle(color.opacity(0.06))
        LineMark(x: .value("Time", sample.date), y: .value(kind.label, value))
          .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5))
      }
    }
    .chartYScale(domain: 0...1)
    .chartXScale(domain: start...end)
    .chartXAxis(.hidden).chartYAxis(.hidden)
    .chartPlotStyle { plot in
      plot.background {
        VStack {
          ForEach(0..<3) { index in
            Rectangle().fill(BlitzUI.panelStroke).frame(height: 0.5)
            if index < 2 { Spacer() }
          }
        }.accessibilityHidden(true)
      }
    }
    .accessibilityLabel("\(kind.label) history")
  }
}

struct HistoryRangePicker: View {
  @Binding var seconds: Double
  var body: some View {
    BlitzSegmentedPicker(
      title: "History range", options: [60.0, 300.0, 900.0, 3_600.0, 86_400.0, 604_800.0],
      selection: $seconds,
      label: { value in
        switch value {
        case 60: "1m"
        case 300: "5m"
        case 900: "15m"
        case 3_600: "1h"
        case 86_400: "24h"
        default: "7d"
        }
      }
    )
    .frame(width: 286)
    .help("CPU and RAM history is stored locally for seven days")
  }
}
