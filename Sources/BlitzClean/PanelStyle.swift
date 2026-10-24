import SwiftUI

extension BlitzStatusTone {
  static func forUsedRatio(_ ratio: Double) -> Self {
    ratio >= 0.95 ? .critical : ratio >= 0.85 ? .warning : .good
  }

  static func forAvailableRatio(_ ratio: Double) -> Self {
    ratio <= 0.1 ? .critical : ratio <= 0.2 ? .warning : .good
  }

  static func forDisk(_ input: DiskCapacityInput) -> Self {
    switch DiskSpacePolicy.status(input) {
    case .healthy: .good
    case .warning: .warning
    case .critical: .critical
    case .unknown: .muted
    }
  }
}

struct CapacityBar: View {
  let usedRatio: Double
  let tone: BlitzStatusTone

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.fill.secondary)
        Capsule()
          .fill(tone.color)
          .frame(width: max(6, geometry.size.width * min(1, max(0, usedRatio))))
      }
    }
    .frame(height: 6)
    .animation(.easeOut(duration: 0.25), value: usedRatio)
  }
}

enum PercentText {
  static func make(_ ratio: Double) -> String {
    (ratio * 100).formatted(.number.precision(.fractionLength(0))) + "%"
  }
}
