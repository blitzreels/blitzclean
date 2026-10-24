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
  @ObservedObject var drive: DriveBreakdownModel
  @ObservedObject var worktrees: DeveloperBrowserModel
  @State private var pending: PendingProcessAction?

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
      recoveryCount: recovery.attentionCount,
      personalFiles: .init(
        oldCount: storage.oldFiles.visibleItems.count, oldBytes: storage.oldFiles.totalBytes,
        oldAge: storage.oldFiles.age.title, largeCount: storage.largeFiles.items.count,
        largeBytes: storage.largeFiles.totalBytes))
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        OverviewDashboard(
          monitor: monitor, memory: memory, processes: processes, recovery: recovery,
          navigation: navigation, storage: storage, drive: drive, history: history,
          worktrees: worktrees,
          pending: $pending)
        if audit.progress.startedAt == nil {
          Button("Run a full checkup") { audit.check(models) }
            .blitzButton(.quiet).controlSize(.small)
            .help(
              "Looks for everything you can remove and everything slowing your Mac. Nothing changes until you choose."
            )
        } else {
          OverviewCleanCard(
            presentation: .init(
              progress: audit.progress, recommendations: findings.recommendations,
              cleanupResult: audit.cleanupResult, isCleaning: cleanup.isCleaning,
              cleaningCompleted: cleanup.completed, cleaningTotal: cleanup.total,
              isMutating: models.isMutating, historyError: history.historyError),
            onCheck: { audit.check(models) }, onAction: perform)
        }
        if let error = monitor.historyPersistenceError {
          BlitzStatusLine(text: error, tone: .warning)
        }
      }.frame(maxWidth: 1040).padding(BlitzUI.pagePadding).frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let action = pending {
        BlitzConfirmation(
          title: action.title, message: action.message, confirmTitle: action.confirmTitle,
          onConfirm: {
            pending = nil
            action.perform()
          }, onCancel: { pending = nil })
      }
    }
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
