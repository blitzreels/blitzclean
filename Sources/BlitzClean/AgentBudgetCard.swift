import SwiftUI

/// How many agent sessions run and whether another one still fits in memory. Six sessions crashed this
/// Mac on October 23, so the card says plainly when the next one would push memory to disk.
struct AgentBudgetCard: View {
  let budget: AgentBudget
  let pressure: MemoryRisk

  private var tone: BlitzStatusTone {
    if budget.room == 0 { return pressure >= .warning ? .critical : .warning }
    return budget.room == 1 ? .warning : .muted
  }

  private var verdict: String {
    switch budget.room {
    case 0: "No room for another session"
    case 1: "Room for 1 more session"
    default: "Room for about \(budget.room) more"
    }
  }

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("\(budget.sessions)").font(BlitzNumberFont.value(26)).monospacedDigit()
          Text(budget.sessions == 1 ? "agent session" : "agent sessions")
            .font(BlitzType.headline).foregroundStyle(BlitzUI.supportingText)
          Text("· \(ByteText.compact(budget.memoryBytes))").font(BlitzType.headline)
            .monospacedDigit().foregroundStyle(BlitzUI.secondaryText)
        }
        Text(budget.mix.joined(separator: " · ")).font(BlitzType.callout)
          .foregroundStyle(BlitzUI.supportingText).lineLimit(1)
        Text(
          "A session uses about \(ByteText.compact(budget.typicalBytes)) with its tools. "
            + (budget.room == 0
              ? "Starting another moves memory to disk and slows every app. Finish or pause one first."
              : "\(ByteText.compact(AgentBudget.reserve)) stays free for apps and builds.")
        ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      BlitzStatusBadge(title: verdict, tone: tone)
    }.blitzCard(padding: 16)
      .accessibilityElement(children: .combine)
  }
}
