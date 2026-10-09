import SwiftUI

struct BlitzOverviewView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var repeats: RepeatCleanupModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var cleanup: QuickCleanModel
  @ObservedObject var history: CleanupOverviewModel
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var docker: DockerStorageModel
  @ObservedObject var audit: DashboardAuditModel
  @AppStorage(MenuBarPreferenceKey.memoryDisplay) private var memoryDisplay = MenuBarMemoryDisplay
    .available

  private var models: DashboardAuditModel.Models {
    .init(
      monitor: monitor, memory: memory, processes: processes, recovery: recovery,
      caches: cleanup, storage: storage, docker: docker)
  }

  var body: some View {
    let detached = processes.threads.filter(\.isDetached)
    let findings = AuditFindings(
      progress: audit.progress,
      cleanup: .init(
        models: .init(caches: cleanup, storage: storage, repeats: repeats, docker: docker)),
      quickBytes: cleanup.quickBytes, canClean: cleanup.canClean,
      pressure: processes.pressure, detachedCount: detached.count,
      detachedBytes: detached.reduce(0) { $0 + $1.memoryBytes },
      recoveryCount: recovery.attentionCount)
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        OverviewCleanCard(
          presentation: .init(
            progress: audit.progress, recommendations: findings.recommendations,
            cleanupResult: audit.cleanupResult, isCleaning: cleanup.isCleaning,
            cleaningCompleted: cleanup.completed, cleaningTotal: cleanup.total,
            isMutating: models.isMutating, historyError: history.historyError),
          vitals: MacVital.all(
            .init(
              snapshot: monitor.snapshot, memoryDisplay: memoryDisplay,
              memoryTone: memory.pressure.tone)),
          onCheck: { audit.check(models) }, onAction: perform, onOpen: open)
        OverviewRecordLine(ledger: history.ledger)
        if let error = monitor.historyPersistenceError {
          BlitzStatusLine(text: error, tone: .warning)
        }
      }.frame(maxWidth: 1040).padding(BlitzUI.pagePadding).frame(maxWidth: .infinity)
    }
  }

  private func open(_ page: CleanPage) {
    if page == .storage { navigation.storagePage = .browse }
    navigation.page = page
  }

  private func perform(_ action: AuditAction) {
    switch action {
    case .cleanCaches: audit.cleanCaches(models)
    case .memory: navigation.page = .memory
    case .cpu: navigation.page = .cpu
    case .recovery: navigation.page = .recovery
    case .cleanup(let focus):
      storage.cleanupFocus = focus
      navigation.storagePage = .cleanup
      navigation.page = .storage
    }
  }
}

/// One line from the removal log: last cleanup, measured space recovered and cleanup count.
struct OverviewRecordLine: View {
  let ledger: CleanupLedger

  var body: some View {
    if let latest = ledger.wins.first {
      let count = ledger.wins.count
      Text(
        "Last cleanup \(latest.date.formatted(.relative(presentation: .named))). \(ByteText.compact(ledger.internalGains)) recovered across \(count.formatted()) \(count == 1 ? "cleanup" : "cleanups")."
      )
      .font(BlitzType.caption).monospacedDigit().foregroundStyle(BlitzUI.secondaryText)
    }
  }
}
