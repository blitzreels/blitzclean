import SwiftUI

struct AuditPresentation {
  let progress: AuditProgress
  let recommendations: [AuditRecommendation]
  let cleanupResult: AuditCleanupResult?
  let isCleaning: Bool
  let cleaningCompleted: Int
  let cleaningTotal: Int
  let isMutating: Bool
  let historyError: String?

  func isDisabled(_ action: AuditAction) -> Bool {
    action == .cleanCaches && (progress.results[.caches] == nil || isMutating)
  }

  var isQuiet: Bool {
    progress.completedAt != nil && recommendations.isEmpty && !isCleaning && cleanupResult == nil
  }

  var title: String {
    if isCleaning { return "Cleaning eligible caches" }
    if progress.isRunning { return "Checking your Mac" }
    if progress.startedAt == nil { return "Ready for a checkup" }
    if !recommendations.isEmpty {
      return
        "\(recommendations.count) \(recommendations.count == 1 ? "thing" : "things") worth doing"
    }
    if let cleanupResult, cleanupResult.outcome.skippedCount > 0 { return "Some caches were kept" }
    return progress.warnings.isEmpty
      ? "Nothing worth cleaning right now" : "No actions in the checked locations"
  }

  var detail: String {
    if isCleaning {
      return "\(cleaningCompleted) of \(cleaningTotal) caches checked before removal"
    }
    if progress.isRunning { return "Findings appear as each check finishes." }
    if progress.startedAt == nil {
      return
        "Finds what you can remove and what is slowing your Mac. Nothing changes until you choose."
    }
    if !progress.warnings.isEmpty { return "Some items were kept or could not be fully checked." }
    return recommendations.isEmpty
      ? "Checked rebuildable storage and current app activity."
      : "Nothing is removed until you choose."
  }
}

extension AuditPresentation {
  var rewardTotal: UInt64 { recommendations.reduce(0) { $0 + ($1.reward ?? 0) } }

  var isBusy: Bool { progress.isRunning || isCleaning }
}

extension AuditCheck {
  var symbol: String {
    switch self {
    case .resources: "memorychip"
    case .caches: "archivebox"
    case .oldFiles: "clock.arrow.circlepath"
    case .projects: "folder"
    case .docker: "shippingbox"
    case .apps: "waveform.path.ecg"
    }
  }

}

extension AuditRecommendation {
  var tone: BlitzStatusTone {
    switch id {
    case "pressure", "sessions": .warning
    case "recovery": .critical
    default: .muted
    }
  }
}

struct OverviewCleanCard: View {
  let presentation: AuditPresentation
  let onCheck: () -> Void
  let onAction: (AuditAction) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsAll = false
  @State private var showsChecks = false
  @State private var showsCleanupDetails = false

  private var visible: [AuditRecommendation] {
    showsAll ? presentation.recommendations : Array(presentation.recommendations.prefix(3))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      hero
      if let result = presentation.cleanupResult { cleanupResult(result) }
      if !visible.isEmpty { moves }
      if let error = presentation.historyError { BlitzStatusLine(text: error, tone: .warning) }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: visible.map(\.id))
  }

  // MARK: Hero

  private var hero: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 14) {
        BlitzIconTile(symbol: "stethoscope", tone: .muted, size: 36)
        VStack(alignment: .leading, spacing: 3) {
          headline
          Text(detailLine).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) {
          Button(action: onCheck) {
            Text(presentation.progress.startedAt == nil ? "Check my Mac" : "Check again")
          }
          .blitzButton(.secondary)
          .controlSize(.small).fixedSize()
          .disabled(presentation.isBusy || presentation.isMutating)
          .help("Audit only. Nothing is removed or stopped by this check.")
          if presentation.progress.startedAt != nil {
            Button(showsChecks ? "Hide details" : "Check details") {
              withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsChecks.toggle() }
            }.blitzButton(.quiet).controlSize(.small).fixedSize()
          }
        }
      }.padding(16)
      if presentation.isCleaning {
        progressBar(
          completed: presentation.cleaningCompleted, total: presentation.cleaningTotal,
          label: "caches checked"
        ).padding(.horizontal, 16).padding(.bottom, 16)
      } else if presentation.progress.isRunning {
        progressBar(
          completed: presentation.progress.results.count, total: AuditCheck.allCases.count,
          label: "checks finished"
        ).padding(.horizontal, 16).padding(.bottom, 16)
      }
      if showsChecks {
        checkDetails.padding(.horizontal, 16).padding(.bottom, 16)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .blitzCard(padding: 0)
  }

  private var detailLine: String {
    guard let date = presentation.progress.completedAt, !presentation.isBusy else {
      return presentation.detail
    }
    return "Checked at \(date.formatted(date: .omitted, time: .shortened)). \(presentation.detail)"
  }

  @ViewBuilder private var headline: some View {
    let reward = presentation.rewardTotal
    if reward > 0, !presentation.isBusy {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Up to \(ByteText.compact(reward)) to reclaim").font(
          .system(size: 15, weight: .semibold)
        ).monospacedDigit().contentTransition(.numericText())
      }.lineLimit(1)
        .accessibilityElement(children: .combine)
    } else {
      Text(presentation.title).font(.system(size: 15, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func progressBar(completed: Int, total: Int, label: String) -> some View {
    let ratio = Double(completed) / Double(max(1, total))
    return GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(BlitzUI.mint.opacity(0.12))
        Capsule().fill(BlitzUI.mint).frame(width: max(8, proxy.size.width * ratio))
      }
    }.frame(height: 6)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: ratio)
      .accessibilityLabel("\(completed) of \(total) \(label)")
  }

  private var checkDetails: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(AuditCheck.allCases, id: \.self) { check in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Label(check.rawValue, systemImage: check.symbol).font(BlitzType.label)
            Spacer()
            Text(presentation.progress.status(for: check))
              .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          }
          if let warnings = presentation.progress.results[check], !warnings.isEmpty {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
              Text(warning).font(BlitzType.caption).foregroundStyle(BlitzUI.warning)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
          }
        }.padding(.vertical, 8)
        if check != AuditCheck.allCases.last { BlitzRowDivider(leading: 0) }
      }
    }
  }

  // MARK: Moves

  private var moves: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Next moves").font(BlitzType.headline)
        Text("\(presentation.recommendations.count)").font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.tertiaryText)
        Spacer(minLength: 8)
        Text(
          presentation.progress.isRunning
            ? "Ready actions are available now" : "Estimates · nothing changes until you choose"
        )
        .font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
      }
      VStack(spacing: 0) {
        ForEach(visible) { recommendation in
          recommendationRow(recommendation)
            .transition(
              .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
          if recommendation.id != visible.last?.id { BlitzRowDivider(leading: 64) }
        }
      }.blitzTable()
      if presentation.recommendations.count > 3 {
        BlitzShowAllButton(
          total: presentation.recommendations.count, noun: "findings", isExpanded: $showsAll)
      }
    }
  }

  private func recommendationRow(_ recommendation: AuditRecommendation) -> some View {
    let primary = isPrimary(recommendation)
    return HStack(spacing: 14) {
      BlitzIconTile(symbol: recommendation.symbol, tone: recommendation.tone, size: 34)
      VStack(alignment: .leading, spacing: 4) {
        Text(recommendation.title).font(BlitzType.rowTitle).monospacedDigit().lineLimit(1)
        Text(recommendation.detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Button(recommendation.actionTitle) { onAction(recommendation.action) }
        .blitzButton(primary ? .accent : .secondary)
        .controlSize(.regular).fixedSize()
        .disabled(presentation.isDisabled(recommendation.action))
    }
    .padding(.vertical, 4)
    .blitzRow()
  }

  private func isPrimary(_ recommendation: AuditRecommendation) -> Bool {
    let primary = visible.first { $0.action == .cleanCaches } ?? visible.first
    return primary?.id == recommendation.id
  }

  // MARK: Cleanup result

  private func cleanupResult(_ result: AuditCleanupResult) -> some View {
    let removed = result.outcome.removedCount > 0
    let tint = removed ? BlitzUI.mint : BlitzUI.warning
    return VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        if removed {
          Text("\(ByteText.full(result.outcome.removedBytes)) removed").font(
            BlitzType.displayNumber
          )
          .foregroundStyle(BlitzUI.mint)
          Text("From eligible caches").font(BlitzType.callout)
            .foregroundStyle(BlitzUI.secondaryText)
        } else {
          Text("No caches were removed").font(BlitzType.title)
        }
      }
      if let gain = result.outcome.availableGain {
        Text(
          gain > 0
            ? "Disk space increased by \(ByteText.full(gain)). Other disk activity affects this reading."
            : "No increase in available disk space was measured. Other activity affects this reading."
        )
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      if result.outcome.skippedCount > 0 {
        Text("\(result.outcome.skippedCount) kept after rechecking; see the reasons below.")
          .font(BlitzType.caption).foregroundStyle(BlitzUI.warning)
      }
      if !result.notes.isEmpty {
        Button(showsCleanupDetails ? "Hide skipped items" : "Why items were kept") {
          showsCleanupDetails.toggle()
        }.blitzButton(.quiet).controlSize(.small)
        if showsCleanupDetails {
          ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
            Text(note).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
              .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          }
        }
      }
      Text(
        result.outcome.availableGain == nil
          ? "Disk-space change could not be measured."
          : "\(result.date.formatted(date: .omitted, time: .shortened)) · Disk space checked again after cleanup"
      )
      .font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
    }
    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    .blitzSurface()
    .overlay { BlitzCelebration(trigger: removed ? result.date : nil) }
  }
}

/// Status of the five checks, which run in parallel: a spinner while running, then a mark.
