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
        "Five checks across storage, Docker, memory, and apps. Nothing is removed until you choose."
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

  func state(for check: AuditCheck) -> AuditCheckState {
    guard progress.startedAt != nil else { return .idle }
    guard let warnings = progress.results[check] else { return .running }
    return warnings.isEmpty ? .done : .partial
  }
}

enum AuditCheckState { case idle, running, done, partial }

extension AuditCheck {
  var symbol: String {
    switch self {
    case .resources: "memorychip"
    case .caches: "archivebox"
    case .projects: "folder"
    case .docker: "shippingbox"
    case .apps: "waveform.path.ecg"
    }
  }

  var shortTitle: String {
    switch self {
    case .resources: "Memory & CPU"
    case .caches: "Caches"
    case .projects: "Projects"
    case .docker: "Docker"
    case .apps: "Apps"
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
  let vitals: [MacVital]
  let onCheck: () -> Void
  let onAction: (AuditAction) -> Void
  let onOpen: (CleanPage) -> Void
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
      HStack(alignment: .center, spacing: 32) {
        BlitzVitalRings(vitals: vitals, lineWidth: 9) {
          ringCenter
        }.frame(width: 172, height: 172)
        VStack(alignment: .leading, spacing: 12) {
          headline
          Text(detailLine).font(BlitzType.callout).foregroundStyle(BlitzUI.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 10) {
            Button(action: onCheck) {
              Text(presentation.progress.startedAt == nil ? "Check my Mac" : "Check again")
            }
            .blitzButton(presentation.recommendations.isEmpty ? .accent : .secondary)
            .controlSize(.large).fixedSize()
            .disabled(presentation.isBusy || presentation.isMutating)
            .help("Audit only. Nothing is removed or stopped by this check.")
            if presentation.progress.startedAt != nil {
              Button(showsChecks ? "Hide details" : "Check details") {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsChecks.toggle() }
              }.blitzButton(.quiet).controlSize(.large).fixedSize()
            }
          }.padding(.top, 4)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 22)
      if presentation.isCleaning {
        cleaningBar.padding(.horizontal, 28).padding(.bottom, 24)
      } else if presentation.progress.startedAt != nil {
        AuditCheckStatusRow(presentation: presentation)
          .padding(.horizontal, 28).padding(.bottom, showsChecks ? 12 : 24)
      }
      if showsChecks {
        checkDetails.padding(.horizontal, 28).padding(.bottom, 20)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
      if !vitals.isEmpty {
        Rectangle().fill(BlitzUI.separator).frame(height: 1)
        vitalStrip
      }
    }
    .blitzHeroCard()
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
        Text("Up to").font(BlitzType.display).foregroundStyle(BlitzUI.primaryText)
        Text(ByteText.compact(reward)).font(BlitzType.display).monospacedDigit()
          .contentTransition(.numericText())
        Text("to reclaim").font(BlitzType.display).foregroundStyle(BlitzUI.primaryText)
      }.lineLimit(1).minimumScaleFactor(0.7).tracking(-0.6)
        .accessibilityElement(children: .combine)
    } else {
      Text(presentation.title).font(BlitzType.display).tracking(-0.6)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var ringCenter: some View {
    let progress = presentation.progress
    if presentation.isCleaning {
      counter(
        "\(presentation.cleaningCompleted)/\(presentation.cleaningTotal)", caption: "cleaned")
    } else if progress.isRunning {
      counter("\(progress.results.count)/\(AuditCheck.allCases.count)", caption: "checks")
    } else if progress.startedAt == nil {
      MacVitalPeak(vitals: vitals, size: 24)
    } else if !presentation.recommendations.isEmpty {
      counter(
        "\(presentation.recommendations.count)",
        caption: presentation.recommendations.count == 1 ? "move" : "moves")
    } else {
      MacVitalPeak(vitals: vitals, size: 24)
    }
  }

  private func counter(_ value: String, caption: String) -> some View {
    VStack(spacing: 0) {
      Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
        .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.6)
      Text(caption).font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
    }
  }

  private var cleaningBar: some View {
    let total = max(1, presentation.cleaningTotal)
    let ratio = Double(presentation.cleaningCompleted) / Double(total)
    return GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(BlitzUI.mint.opacity(0.12))
        Capsule().fill(BlitzUI.mint).frame(width: max(8, proxy.size.width * ratio))
      }
    }.frame(height: 6)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: ratio)
      .accessibilityLabel("\(presentation.cleaningCompleted) of \(total) caches checked")
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

  private var vitalStrip: some View {
    HStack(spacing: 0) {
      ForEach(Array(vitals.enumerated()), id: \.element.id) { index, vital in
        if index > 0 { Rectangle().fill(BlitzUI.separator).frame(width: 1, height: 40) }
        Button {
          onOpen(vital.page)
        } label: {
          HStack(alignment: .center) {
            MacVitalLabel(vital: vital)
            Spacer(minLength: 4)
            BlitzChevron()
          }.padding(.horizontal, 14).padding(.vertical, 12)
        }.buttonStyle(BlitzRowButtonStyle(radius: 12)).help("Open \(vital.title)")
      }
    }.padding(6)
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
      BlitzIconTile(symbol: recommendation.symbol, tone: recommendation.tone)
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
    .blitzHeroCard()
    .overlay { BlitzCelebration(trigger: removed ? result.date : nil) }
  }
}

/// Status of the five checks, which run in parallel: a spinner while running, then a mark.
private struct AuditCheckStatusRow: View {
  let presentation: AuditPresentation

  var body: some View {
    HStack(spacing: 18) {
      ForEach(AuditCheck.allCases, id: \.self) { check in
        let state = presentation.state(for: check)
        HStack(spacing: 6) {
          mark(state).frame(width: 12, height: 12)
          Text(check.shortTitle).font(BlitzType.caption).lineLimit(1).fixedSize()
            .foregroundStyle(state == .running ? BlitzUI.secondaryText : BlitzUI.supportingText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.rawValue): \(presentation.progress.status(for: check))")
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder private func mark(_ state: AuditCheckState) -> some View {
    switch state {
    case .running: AuditSpinner()
    case .done:
      Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
        .foregroundStyle(BlitzUI.mint)
    case .partial:
      Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold))
        .foregroundStyle(BlitzUI.warning)
    case .idle: EmptyView()
    }
  }
}

private struct AuditSpinner: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      Circle().strokeBorder(BlitzUI.secondaryText, lineWidth: 1.5)
    } else {
      TimelineView(.animation) { timeline in
        let angle =
          timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
          * 360
        Circle().trim(from: 0, to: 0.28)
          .stroke(BlitzUI.secondaryText, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
          .rotationEffect(.degrees(angle)).padding(1)
      }
    }
  }
}
