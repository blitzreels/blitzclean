import SwiftUI

struct PressureBanner: View {
  struct Review {
    let title: String
    let action: () -> Void
  }

  let assessment: PressureAssessment
  /// Absent on the page that already resolves the pressure.
  let review: Review?

  private var tone: MetricTone { assessment.risk.tone }

  var body: some View {
    if assessment.risk > .normal {
      alert
    } else {
      HStack(spacing: 10) {
        BlitzStatusDot(tone: .good, diameter: 7)
        Text(assessment.title).font(BlitzType.label)
        Text(assessment.detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
      }.padding(.horizontal, 4)
    }
  }

  private var alert: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14))
        .foregroundStyle(tone.color).frame(width: 18).padding(.top, 1)
      VStack(alignment: .leading, spacing: 6) {
        Text(assessment.title).font(BlitzType.section)
        if !assessment.action.isEmpty {
          Text(assessment.action).font(BlitzType.body).foregroundStyle(BlitzUI.supportingText)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(assessment.detail).font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      if let review {
        Button(review.title, action: review.action).blitzButton(.secondary).controlSize(.small)
      }
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).blitzToneCard(tone)
  }
}
