import SwiftUI

struct PressureBanner: View {
  let assessment: PressureAssessment
  let actionTitle: String
  let onReview: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(
          systemName: assessment.risk > .normal
            ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent"
        )
        .foregroundStyle(
          assessment.risk >= .critical
            ? Color.red : assessment.risk > .normal ? .orange : BlitzUI.mint)
        Text(assessment.title).font(BlitzType.section)
        Spacer()
        if assessment.risk > .normal {
          Button(actionTitle, action: onReview).blitzButton(.secondary).controlSize(.small)
        }
      }
      Text(assessment.detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      if !assessment.action.isEmpty {
        Text(assessment.action).font(BlitzType.body)
          .fixedSize(horizontal: false, vertical: true)
      }
    }.panelCard(padding: 16)
  }
}
