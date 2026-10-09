import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

@MainActor
struct DashboardAuditTests {
  @Test func readyCacheActionDoesNotWaitForProjectScan() {
    var progress = AuditProgress()
    progress.begin(at: .now)
    progress.finish(.init(check: .caches, warnings: [], date: .now))
    let view = AuditPresentation(
      progress: progress, recommendations: [], cleanupResult: nil, isCleaning: false,
      cleaningCompleted: 0, cleaningTotal: 0, isMutating: false, historyError: nil)
    #expect(progress.isRunning)
    #expect(!view.isDisabled(.cleanCaches))
  }

  @Test func rechecksWaitForCurrentAuditAndCoalesceIntoOneFreshRun() async throws {
    let model = DashboardAuditModel()
    let gate = AuditCheckGate()
    model.start(
      .init(checks: [
        .projects: {
          await gate.wait()
          return []
        }
      ]))
    for _ in 0..<100 where model.progress.results.count < 4 {
      try await Task.sleep(for: .milliseconds(5))
    }
    var refreshCalls = 0
    let checks: [AuditCheck: DashboardAuditModel.Check] = Dictionary(
      uniqueKeysWithValues: AuditCheck.allCases.map { check in
        let run: DashboardAuditModel.Check = {
          refreshCalls += 1
          return []
        }
        return (check, run)
      })
    model.recheck(.init(checks: checks))
    model.recheck(.init(checks: checks))
    #expect(refreshCalls == 0)
    await gate.release()
    for _ in 0..<100 where model.progress.isRunning || refreshCalls < 5 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(refreshCalls == 5)
    #expect(model.progress.completedAt != nil)
    #expect(model.progress.warnings.isEmpty)
  }

  @Test func cacheActionStaysDisabledUntilCheckedAndDuringMutations() {
    for checked in [false, true] {
      var progress = AuditProgress()
      progress.begin(at: .now)
      if checked { progress.finish(.init(check: .caches, warnings: [], date: .now)) }
      let view = AuditPresentation(
        progress: progress, recommendations: [], cleanupResult: nil, isCleaning: false,
        cleaningCompleted: 0, cleaningTotal: 0, isMutating: checked, historyError: nil)
      #expect(view.isDisabled(.cleanCaches))
      #expect(!view.isDisabled(.cleanup(.projects)))
    }
  }
  @Test func progressDoesNotFinishEarlyAndNewAuditClearsOldResults() {
    var progress = AuditProgress()
    #expect(!progress.isRunning)
    #expect(progress.completedAt == nil)
    #expect(progress.status(for: .caches) == "Not checked")
    progress.begin(at: .now)
    for check in AuditCheck.allCases.dropLast() {
      progress.finish(.init(check: check, warnings: [], date: .now))
    }
    #expect(progress.isRunning)
    #expect(progress.completedAt == nil)
    #expect(progress.status(for: .apps) == "Checking…")
    progress.finish(.init(check: .apps, warnings: ["Unavailable"], date: .now))
    #expect(!progress.isRunning)
    #expect(progress.warnings == ["App responsiveness: Unavailable"])
    #expect(progress.status(for: .apps) == "Partly checked")
    progress.begin(at: .now)
    #expect(progress.results.isEmpty)
    #expect(progress.completedAt == nil)
  }

  @Test func auditPublishesFastChecksBeforeSlowChecksAndRejectsDuplicateRuns() async throws {
    let model = DashboardAuditModel()
    let gate = AuditCheckGate()
    var calls = 0
    let checks: [AuditCheck: DashboardAuditModel.Check] = Dictionary(
      uniqueKeysWithValues: AuditCheck.allCases.map { check in
        let run: DashboardAuditModel.Check = {
          calls += 1
          if check == .projects { await gate.wait() }
          return check == .docker ? ["Docker is unavailable"] : []
        }
        return (check, run)
      })
    model.start(.init(checks: checks))
    model.start(.init(checks: checks))
    for _ in 0..<100 where model.progress.results.count < 4 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.progress.results.count == 4)
    #expect(model.progress.isRunning)
    #expect(calls == 5)
    await gate.release()
    for _ in 0..<100 where model.progress.isRunning {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.progress.completedAt != nil)
    #expect(model.progress.warnings == ["Docker: Docker is unavailable"])
  }

  @Test func missingCheckIsExplicitlyUnavailable() async throws {
    let model = DashboardAuditModel()
    model.start(.init(checks: [:]))
    for _ in 0..<100 where model.progress.isRunning {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.progress.warnings.count == AuditCheck.allCases.count)
  }

  @Test func findingsHidePreviousScanDataUntilThatCheckFinishes() {
    var progress = AuditProgress()
    progress.begin(at: .now)
    let summary = OverviewCleanupSummary(
      .init(
        items: [], dockerBytes: 3_000_000_000, hasSkippedLocations: false, dockerUnavailable: false)
    )
    #expect(findings(.init(progress: progress, summary: summary)).recommendations.isEmpty)
    progress.finish(.init(check: .caches, warnings: [], date: .now))
    #expect(
      findings(.init(progress: progress, summary: summary)).recommendations.map(\.id) == ["caches"])
    progress.finish(.init(check: .docker, warnings: [], date: .now))
    #expect(
      findings(.init(progress: progress, summary: summary)).recommendations.map(\.id) == [
        "caches", "docker",
      ])
  }

  @Test func cachesAreOnlyDirectRemovalAndUrgentPressureRanksFirst() {
    let summary = OverviewCleanupSummary(
      .init(
        items: [
          .init(path: "/projects", bytes: 20_000_000_000, source: .projects),
          .init(path: "/reports", bytes: 2_000_000_000, source: .reports),
          .init(path: "/devices", bytes: 5_000_000_000, source: .simulators),
        ], dockerBytes: 3_000_000_000, hasSkippedLocations: false, dockerUnavailable: false))
    let result = findings(.init(progress: AuditRenderFixture.complete, summary: summary))
    let urgent = AuditFindings(
      progress: result.progress, cleanup: result.cleanup, quickBytes: result.quickBytes,
      canClean: true,
      pressure: .init(
        risk: .critical, limit: .memory, title: "Memory under pressure", detail: "",
        action: "Review memory", date: .now),
      detachedCount: 2, detachedBytes: 4_000_000_000, recoveryCount: 1)
    #expect(urgent.recommendations.prefix(3).map(\.id) == ["pressure", "recovery", "caches"])
    #expect(urgent.recommendations.filter { $0.action == .cleanCaches }.map(\.id) == ["caches"])
    #expect(urgent.recommendations.first { $0.id == "docker" }?.action == .cleanup(.docker))
    #expect(urgent.recommendations.first { $0.id == "simulators" }?.action == .cleanup(.simulators))
  }

  @Test func emptyAndIncompleteAuditsNeverInventCleanupOrSuccess() {
    let empty = OverviewCleanupSummary(
      .init(items: [], dockerBytes: 0, hasSkippedLocations: false, dockerUnavailable: false))
    let findings = AuditFindings(
      progress: AuditRenderFixture.complete, cleanup: empty, quickBytes: 0, canClean: false,
      pressure: .checking, detachedCount: 0, detachedBytes: 0, recoveryCount: 0)
    #expect(findings.recommendations.isEmpty)
    let completed = AuditRenderFixture.presentation(findings)
    #expect(completed.title == "Nothing worth cleaning right now")
    var incomplete = AuditProgress()
    incomplete.begin(at: .now)
    for check in AuditCheck.allCases {
      incomplete.finish(
        .init(check: check, warnings: check == .docker ? ["Unavailable"] : [], date: .now))
    }
    let partial = AuditPresentation(
      progress: incomplete, recommendations: [], cleanupResult: nil, isCleaning: false,
      cleaningCompleted: 0, cleaningTotal: 0, isMutating: false, historyError: nil)
    #expect(partial.title != completed.title)
    #expect(partial.detail.contains("could not be fully checked"))
  }

  @Test func rendersDashboardStatesWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["BLITZCLEAN_AUDIT_RENDER_DIR"] else {
      return
    }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let summary = OverviewCleanupSummary(
      .init(
        items: [], dockerBytes: 3_100_000_000, hasSkippedLocations: false, dockerUnavailable: false)
    )
    let recommendations = findings(.init(progress: AuditRenderFixture.complete, summary: summary))
      .recommendations
    var scanning = AuditProgress()
    scanning.begin(at: .now)
    scanning.finish(.init(check: .caches, warnings: [], date: .now))
    let states: [(String, AuditPresentation)] = [
      (
        "initial",
        .init(
          progress: .init(), recommendations: [], cleanupResult: nil, isCleaning: false,
          cleaningCompleted: 0, cleaningTotal: 0, isMutating: false, historyError: nil)
      ),
      (
        "findings",
        .init(
          progress: AuditRenderFixture.complete, recommendations: recommendations,
          cleanupResult: nil, isCleaning: false, cleaningCompleted: 0, cleaningTotal: 0,
          isMutating: false, historyError: nil)
      ),
      (
        "scanning",
        .init(
          progress: scanning, recommendations: recommendations, cleanupResult: nil,
          isCleaning: false, cleaningCompleted: 0, cleaningTotal: 0, isMutating: false,
          historyError: nil)
      ),
      (
        "empty",
        .init(
          progress: AuditRenderFixture.complete, recommendations: [], cleanupResult: nil,
          isCleaning: false, cleaningCompleted: 0, cleaningTotal: 0, isMutating: false,
          historyError: nil)
      ),
      (
        "cleaning",
        .init(
          progress: AuditRenderFixture.complete, recommendations: [], cleanupResult: nil,
          isCleaning: true, cleaningCompleted: 1, cleaningTotal: 3, isMutating: true,
          historyError: nil)
      ),
      (
        "cleaned",
        .init(
          progress: AuditRenderFixture.complete, recommendations: [],
          cleanupResult: .init(
            outcome: .init(
              removedCount: 2, skippedCount: 1, removedBytes: 8_200_000_000,
              availableGain: 8_000_000_000),
            notes: ["One cache changed after the audit and was kept."], date: .now),
          isCleaning: false, cleaningCompleted: 3, cleaningTotal: 3, isMutating: false,
          historyError: nil)
      ),
    ]
    for (name, presentation) in states {
      for width in [708.0, 988.0] {
        let renderer = ImageRenderer(
          content: OverviewCleanCard(
            presentation: presentation, vitals: AuditRenderFixture.vitals, onCheck: {},
            onAction: { _ in }, onOpen: { _ in }
          )
          .padding(28).frame(width: width).background(BlitzUI.canvasBackground).blitzTheme())
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(
          NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name)-\(Int(width)).png"))
      }
    }
  }

  private struct FindingsInput {
    let progress: AuditProgress
    let summary: OverviewCleanupSummary
  }

  private func findings(_ input: FindingsInput) -> AuditFindings {
    .init(
      progress: input.progress, cleanup: input.summary, quickBytes: 8_200_000_000, canClean: true,
      pressure: .checking, detachedCount: 0, detachedBytes: 0, recoveryCount: 0)
  }
}

private actor AuditCheckGate {
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
enum AuditRenderFixture {
  struct Input {
    let model: QuickCleanModel
    let summary: OverviewCleanupSummary
    let isScanning: Bool
  }

  static var complete: AuditProgress {
    var progress = AuditProgress()
    progress.begin(at: .now)
    for check in AuditCheck.allCases {
      progress.finish(.init(check: check, warnings: [], date: .now))
    }
    return progress
  }

  static func presentation(_ findings: AuditFindings) -> AuditPresentation {
    .init(
      progress: findings.progress, recommendations: findings.recommendations, cleanupResult: nil,
      isCleaning: false, cleaningCompleted: 0, cleaningTotal: 0, isMutating: false,
      historyError: nil)
  }

  static func card(_ input: Input) -> some View {
    var progress = AuditProgress()
    progress.begin(at: .now)
    if !input.isScanning {
      for check in AuditCheck.allCases {
        let warnings =
          check == .docker && input.summary.dockerUnavailable
          ? ["Docker could not be checked."] : []
        progress.finish(.init(check: check, warnings: warnings, date: .now))
      }
    }
    let findings = AuditFindings(
      progress: progress, cleanup: input.summary, quickBytes: input.model.quickBytes,
      canClean: input.model.canClean, pressure: .checking, detachedCount: 0, detachedBytes: 0,
      recoveryCount: 0)
    return OverviewCleanCard(
      presentation: .init(
        progress: progress, recommendations: findings.recommendations,
        cleanupResult: input.model.result.map {
          .init(outcome: $0, notes: input.model.notes, date: .now)
        },
        isCleaning: input.model.isCleaning, cleaningCompleted: input.model.completed,
        cleaningTotal: input.model.total, isMutating: input.model.isBusy, historyError: nil),
      vitals: vitals, onCheck: {}, onAction: { _ in }, onOpen: { _ in })
  }

  static var vitals: [MacVital] {
    let gib: UInt64 = 1 << 30
    let snapshot = SystemSnapshot(
      .init(
        diskAvailable: 26 * gib, diskTotal: 460 * gib, ramAvailable: 10 * gib,
        ramTotal: 36 * gib, memoryPressure: .normal, cpuUsage: 0.22, thermalStatus: .nominal,
        updatedAt: .now))
    return MacVital.all(.init(snapshot: snapshot, memoryDisplay: .available, memoryTone: .good))
  }
}
