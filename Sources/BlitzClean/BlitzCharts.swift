import SwiftUI

extension BlitzStatusTone {
  /// The fill for a reading: mint while it is fine, neutral ink for plain amounts, the tone's color
  /// when it needs attention.
  var meterColor: Color {
    switch self {
    case .warning, .critical: color
    case .good: BlitzUI.mint
    case .working, .muted: Color.white.opacity(0.62)
    }
  }
}

/// A ring that fills to a fraction, swept in on appear and eased on every change.
struct BlitzRingGauge<Center: View>: View {
  let fraction: Double
  let tone: BlitzStatusTone
  let size: CGFloat
  let lineWidth: CGFloat
  @ViewBuilder let center: () -> Center
  @State private var shown = 0.0

  var body: some View {
    let color = tone.meterColor
    ZStack {
      Circle().stroke(Color.white.opacity(0.07), lineWidth: lineWidth)
      Circle().trim(from: 0, to: shown)
        .stroke(
          AngularGradient(
            colors: [color.opacity(0.35), color], center: .center,
            startAngle: .degrees(0), endAngle: .degrees(360 * max(shown, 0.01))),
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .shadow(color: color.opacity(0.45), radius: 6)
      center()
    }
    .frame(width: size, height: size)
    .onAppear {
      withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) { shown = clamped }
    }
    .onChange(of: fraction) {
      withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { shown = clamped }
    }
    .accessibilityElement(children: .combine)
  }

  private var clamped: Double { min(1, max(0, fraction)) }
}

/// A thin capsule meter: neutral track, tone-colored fill that eases to each new value.
struct BlitzMeter: View {
  let fraction: Double
  let tone: BlitzStatusTone
  let height: CGFloat

  var body: some View {
    let color = tone.meterColor
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.07))
        Capsule()
          .fill(
            LinearGradient(
              colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing)
          )
          .frame(width: max(height, geometry.size.width * min(1, max(0, fraction))))
          .opacity(fraction > 0 ? 1 : 0)
      }
    }
    .frame(height: height)
    .animation(.spring(response: 0.5, dampingFraction: 0.9), value: fraction)
    .accessibilityHidden(true)
  }
}

/// Progress for long work: a filling bar when the share done is known, a moving sheen when it is not.
struct BlitzProgressBar: View {
  let fraction: Double?
  let height: CGFloat
  @State private var phase = -0.4

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.07))
        if let fraction {
          Capsule()
            .fill(
              LinearGradient(
                colors: [BlitzUI.mint.opacity(0.6), BlitzUI.mint], startPoint: .leading,
                endPoint: .trailing)
            )
            .frame(width: max(height, width * min(1, max(0, fraction))))
            .overlay(sheen(width: width))
            .clipShape(Capsule())
            .shadow(color: BlitzUI.mint.opacity(0.4), radius: 4)
            .animation(.easeOut(duration: 0.3), value: fraction)
        } else {
          Capsule()
            .fill(
              LinearGradient(
                colors: [
                  BlitzUI.mint.opacity(0), BlitzUI.mint.opacity(0.85), BlitzUI.mint.opacity(0),
                ],
                startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: width * 0.35)
            .offset(x: width * phase)
        }
      }.clipShape(Capsule())
    }
    .frame(height: height)
    .onAppear {
      withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.05 }
    }
    .accessibilityElement()
    .accessibilityLabel("Progress")
    .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
  }

  private func sheen(width: CGFloat) -> some View {
    LinearGradient(
      colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0)], startPoint: .leading,
      endPoint: .trailing
    )
    .frame(width: width * 0.25)
    .offset(x: width * phase)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A compact trend line with a soft fill and a glowing dot on the latest value.
struct BlitzSparkline: View {
  let values: [Double]
  let tone: BlitzStatusTone

  var body: some View {
    let color = tone.meterColor
    GeometryReader { geometry in
      let points = Self.points(values, in: geometry.size)
      if points.count > 1, let last = points.last {
        ZStack(alignment: .topLeading) {
          Path { path in
            path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
            for point in points { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: geometry.size.height))
            path.closeSubpath()
          }.fill(
            LinearGradient(
              colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
          Path { path in
            path.addLines(points)
          }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
          Circle().fill(color).frame(width: 5, height: 5)
            .shadow(color: color, radius: 3)
            .position(last)
        }
      }
    }
    .accessibilityHidden(true)
  }

  static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
    guard values.count > 1 else { return [] }
    let step = size.width / CGFloat(values.count - 1)
    return values.enumerated().map { index, value in
      CGPoint(
        x: CGFloat(index) * step,
        y: 2 + (size.height - 4) * (1 - CGFloat(min(1, max(0, value)))))
    }
  }

  /// Evenly thins a series to at most `count` values, keeping the newest.
  static func thinned(_ values: [Double], to count: Int) -> [Double] {
    guard values.count > count, count > 1 else { return values }
    let step = Double(values.count - 1) / Double(count - 1)
    return (0..<count).map { values[Int((Double($0) * step).rounded())] }
  }
}
