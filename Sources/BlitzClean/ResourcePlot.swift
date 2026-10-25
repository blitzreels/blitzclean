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
  /// Percentage gridline labels and the hover readout, for the full-size page charts.
  let isDetailed: Bool
  @State private var hovered: ResourceSample?

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

  /// The chart starts at the oldest visible sample, so a short history fills the width.
  private func start(_ visible: [ResourceSample]) -> Date {
    max(
      end.addingTimeInterval(-seconds), min(visible.first?.date ?? end, end.addingTimeInterval(-20))
    )
  }

  var body: some View {
    let visible = visibleSamples
    let latest = visible.last { kind.value($0) != nil }
    Chart {
      ForEach(visible) { sample in
        if let value = kind.value(sample) {
          AreaMark(x: .value("Time", sample.date), y: .value(kind.label, value))
            .foregroundStyle(
              LinearGradient(
                colors: [color.opacity(0.34), color.opacity(0.02)], startPoint: .top,
                endPoint: .bottom)
            )
            .interpolationMethod(.monotone)
          LineMark(x: .value("Time", sample.date), y: .value(kind.label, value))
            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            .interpolationMethod(.monotone)
        }
      }
      if let latest, let value = kind.value(latest), hovered == nil {
        PointMark(x: .value("Time", latest.date), y: .value(kind.label, value))
          .symbolSize(isDetailed ? 46 : 18).foregroundStyle(color)
      }
      if isDetailed, let hovered, let value = kind.value(hovered) {
        RuleMark(x: .value("Time", hovered.date))
          .foregroundStyle(Color.white.opacity(0.22)).lineStyle(StrokeStyle(lineWidth: 1))
        PointMark(x: .value("Time", hovered.date), y: .value(kind.label, value))
          .symbolSize(60).foregroundStyle(color)
          .annotation(
            position: .top, spacing: 6,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            readout(hovered, value: value)
          }
      }
    }
    .chartYScale(domain: 0...1)
    .chartXScale(domain: start(visible)...end)
    .chartXAxis(.hidden)
    .chartYAxis {
      if isDetailed {
        AxisMarks(position: .trailing, values: [0, 0.5, 1]) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            .foregroundStyle(BlitzUI.panelStroke)
          AxisValueLabel {
            if let fraction = value.as(Double.self) {
              Text("\(Int(fraction * 100))%").font(BlitzType.caption)
                .foregroundStyle(BlitzUI.tertiaryText)
            }
          }
        }
      }
    }
    .chartOverlay { proxy in
      if isDetailed {
        GeometryReader { geometry in
          Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                guard let plot = proxy.plotFrame else { return }
                let x = location.x - geometry[plot].origin.x
                guard let date: Date = proxy.value(atX: x) else { return }
                hovered = Self.nearest(date, in: visible)
              case .ended:
                hovered = nil
              }
            }
        }
      }
    }
    .accessibilityLabel("\(kind.label) history")
  }

  private func readout(_ sample: ResourceSample, value: Double) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(PercentText.make(value)).font(BlitzType.label).monospacedDigit()
      Text(
        sample.date,
        format: seconds > 86_400 ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute()
      )
      .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
    .background(BlitzUI.menuFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(BlitzUI.panelStroke)
    }
  }

  static func nearest(_ date: Date, in samples: [ResourceSample]) -> ResourceSample? {
    var low = samples.startIndex
    var high = samples.endIndex
    while low < high {
      let mid = (low + high) / 2
      if samples[mid].date < date { low = mid + 1 } else { high = mid }
    }
    let candidates = [low - 1, low].filter { samples.indices.contains($0) }
    return candidates.map { samples[$0] }.min {
      abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
    }
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
