import SwiftUI

struct MemoryGraphView: View {
  let samples: [MemorySample]
  let risk: MemoryRisk

  private var currentSample: MemorySample? {
    samples.last
  }

  private var tint: Color {
    risk > .normal ? risk.tone.color : .accentColor
  }

  var body: some View {
    MemoryHistoryPlot(
      input: MemoryHistoryPlotInput(
        samples: samples,
        tint: tint
      )
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Memory usage, 5 minute history")
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    guard let currentSample else {
      return "Unavailable"
    }

    let percentage = (currentSample.usedRatio * 100).formatted(
      .number.precision(.fractionLength(0))
    )
    let used = ByteText.full(currentSample.used)
    let total = ByteText.full(currentSample.total)
    return "\(percentage) percent used, \(used) of \(total)"
  }
}

private struct MemoryHistoryPlotInput {
  let samples: [MemorySample]
  let tint: Color
}

private struct MemoryHistoryPlot: View {
  let input: MemoryHistoryPlotInput

  var body: some View {
    GeometryReader { geometry in
      let points = graphPoints(size: geometry.size)

      ZStack {
        RoundedRectangle(cornerRadius: PanelMetrics.innerRadius)
          .fill(.fill.quaternary)

        grid

        if let areaPath = areaPath(
          input: AreaPathInput(
            points: points,
            size: geometry.size
          )
        ) {
          areaPath.fill(
            LinearGradient(
              colors: [input.tint.opacity(0.34), input.tint.opacity(0.04)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
        }

        linePath(points: points)
          .stroke(
            input.tint,
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
          )
      }
      .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.innerRadius))
    }
  }

  private var grid: some View {
    VStack(spacing: 0) {
      Divider()
      Spacer()
      Divider()
      Spacer()
      Divider()
    }
    .opacity(0.35)
  }

  private func graphPoints(size: CGSize) -> [CGPoint] {
    guard let firstSample = input.samples.first else {
      return []
    }

    if input.samples.count == 1 {
      let ratio = min(1, max(0, firstSample.usedRatio))
      let y = size.height * (1 - CGFloat(ratio))
      return [CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)]
    }

    let denominator = input.samples.count - 1
    return input.samples.enumerated().map { index, sample in
      let x = size.width * CGFloat(index) / CGFloat(denominator)
      let ratio = min(1, max(0, sample.usedRatio))
      let y = size.height * (1 - CGFloat(ratio))
      return CGPoint(x: x, y: y)
    }
  }

  private func linePath(points: [CGPoint]) -> Path {
    Path { path in
      guard let firstPoint = points.first else {
        return
      }

      path.move(to: firstPoint)
      for point in points.dropFirst() {
        path.addLine(to: point)
      }
    }
  }

  private func areaPath(input: AreaPathInput) -> Path? {
    guard let firstPoint = input.points.first, let lastPoint = input.points.last else {
      return nil
    }

    return Path { path in
      path.move(to: CGPoint(x: firstPoint.x, y: input.size.height))
      path.addLine(to: firstPoint)
      for point in input.points.dropFirst() {
        path.addLine(to: point)
      }
      path.addLine(to: CGPoint(x: lastPoint.x, y: input.size.height))
      path.closeSubpath()
    }
  }
}

private struct AreaPathInput {
  let points: [CGPoint]
  let size: CGSize
}
