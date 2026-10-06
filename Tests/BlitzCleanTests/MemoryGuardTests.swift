import Foundation
import Testing

@testable import BlitzClean

struct MemoryGuardTests {
  private let gib: UInt64 = 1_024 * 1_024 * 1_024

  @Test
  func warnsOnSustainedSwapActivityBeforeNativeWarning() {
    var evaluator = MemoryRiskEvaluator()
    #expect(
      evaluator.evaluate(sample(.init(seconds: 0, pressure: .normal, swapOutMiB: 0))) == .normal)
    #expect(
      evaluator.evaluate(sample(.init(seconds: 15, pressure: .normal, swapOutMiB: 80))) == .normal)
    #expect(
      evaluator.evaluate(sample(.init(seconds: 30, pressure: .normal, swapOutMiB: 160))) == .growing
    )
  }

  @Test
  func existingSwapAloneDoesNotAlert() {
    var evaluator = MemoryRiskEvaluator()
    for second in stride(from: 0, through: 180, by: 5) {
      #expect(
        evaluator.evaluate(sample(.init(seconds: second, pressure: .normal, swapOutMiB: 10_000)))
          == .normal)
    }
  }

  @Test
  func nativeCriticalEscalatesImmediatelyAndRecoveryIsSustained() {
    var evaluator = MemoryRiskEvaluator()
    #expect(
      evaluator.evaluate(sample(.init(seconds: 0, pressure: .warning, swapOutMiB: 0))) == .warning)
    #expect(
      evaluator.evaluate(sample(.init(seconds: 1, pressure: .critical, swapOutMiB: 0))) == .critical
    )
    #expect(
      evaluator.evaluate(sample(.init(seconds: 5, pressure: .normal, swapOutMiB: 0))) == .critical)
    #expect(
      evaluator.evaluate(sample(.init(seconds: 34, pressure: .normal, swapOutMiB: 0))) == .critical)
    #expect(
      evaluator.evaluate(sample(.init(seconds: 35, pressure: .normal, swapOutMiB: 0))) == .normal)
  }

  @Test
  func sleepGapsAndCounterResetsCannotCreateGrowthAlerts() {
    var evaluator = MemoryRiskEvaluator()
    _ = evaluator.evaluate(sample(.init(seconds: 0, pressure: .normal, swapOutMiB: 500)))
    #expect(
      evaluator.evaluate(sample(.init(seconds: 30, pressure: .normal, swapOutMiB: 0))) == .normal)
    #expect(
      evaluator.evaluate(sample(.init(seconds: 900, pressure: .normal, swapOutMiB: 50_000)))
        == .normal)
  }

  @Test
  func alertCooldownAllowsEscalationWithoutRepeatedBanners() {
    var gate = MemoryAlertGate()
    let date = Date(timeIntervalSince1970: 1_000)
    #expect(gate.shouldSend(.init(risk: .warning, date: date)) == true)
    #expect(gate.shouldSend(.init(risk: .warning, date: date.addingTimeInterval(5))) == false)
    #expect(gate.shouldSend(.init(risk: .critical, date: date.addingTimeInterval(10))) == true)
    #expect(gate.shouldSend(.init(risk: .normal, date: date.addingTimeInterval(40))) == false)
    #expect(gate.shouldSend(.init(risk: .warning, date: date.addingTimeInterval(50))) == false)
    #expect(gate.shouldSend(.init(risk: .warning, date: date.addingTimeInterval(611))) == true)
  }

  @Test
  func recommendationsPrioritizeUserChoicesAndNeverSuggestProtectedOrForegroundApps() {
    let ai = app(
      .init(id: 1, name: "ChatGPT", bytes: 16 * gib, protected: "AI workers", active: false))
    let foreground = app(.init(id: 2, name: "Editor", bytes: 8 * gib, protected: nil, active: true))
    let review = app(.init(id: 3, name: "Browser", bytes: 4 * gib, protected: nil, active: false))
    let disposable = app(.init(id: 4, name: "Music", bytes: gib, protected: nil, active: false))
    let pinned = app(.init(id: 5, name: "Meeting", bytes: 6 * gib, protected: nil, active: false))
    let ranked = MemoryCandidateRanker.rank(
      .init(
        apps: [ai, foreground, review, disposable, pinned],
        policies: [disposable.policyKey: .disposable, pinned.policyKey: .keepRunning],
        lastActive: [:], growth: [:], date: .now
      ))
    #expect(ranked.filter { !$0.protected }.map(\.id) == [4, 3])
    #expect(ranked.first(where: { $0.id == 3 })?.reason.contains("unknown") == true)
  }

  @Test
  func explicitQuitSkipsSuggestionGuardsButStillChecksIdentity() {
    let expected = app(
      .init(id: 7, name: "Cursor", bytes: gib, protected: "AI and coding app", active: true))
    let current = descriptor(
      .init(
        app: expected, active: true, launchDate: expected.launchDate,
        protected: "AI and coding app"))
    #expect(
      MemoryQuitSafety.refusal(.init(expected: expected, current: current, policy: .review)) != nil)
    #expect(
      MemoryQuitSafety.refusal(
        .init(expected: expected, current: current, policy: .keepRunning, explicit: true)) == nil)
    let relaunched = descriptor(
      .init(app: expected, active: true, launchDate: .now, protected: nil))
    #expect(
      MemoryQuitSafety.refusal(
        .init(expected: expected, current: relaunched, policy: .review, explicit: true)) != nil)
  }

  @Test
  func quitRevalidatesIdentityProtectionAndCurrentActivity() {
    let expected = app(.init(id: 3, name: "Browser", bytes: gib, protected: nil, active: false))
    let current = descriptor(
      .init(app: expected, active: false, launchDate: expected.launchDate, protected: nil))
    #expect(
      MemoryQuitSafety.refusal(.init(expected: expected, current: current, policy: .review)) == nil)
    #expect(
      MemoryQuitSafety.refusal(.init(expected: expected, current: nil, policy: .review)) != nil)
    #expect(
      MemoryQuitSafety.refusal(.init(expected: expected, current: current, policy: .keepRunning))
        != nil)
    for candidate in [
      descriptor(
        .init(app: expected, active: true, launchDate: expected.launchDate, protected: nil)),
      descriptor(.init(app: expected, active: false, launchDate: .now, protected: nil)),
      descriptor(.init(app: expected, active: false, launchDate: nil, protected: nil)),
      descriptor(
        .init(app: expected, active: false, launchDate: expected.launchDate, protected: "AI worker")
      ),
    ] {
      #expect(
        MemoryQuitSafety.refusal(.init(expected: expected, current: candidate, policy: .review))
          != nil)
    }
  }

  @Test
  func defaultProtectionCoversAIAndTerminalAppsWithoutProtectingEveryMissingBundleID() {
    for name in ["ChatGPT", "Claude", "Codex", "Cursor", "cmux", "iTerm2", "Terminal", "Ghostty"] {
      #expect(
        MemoryAppProtection.reason(
          .init(
            processID: 100, bundleIdentifier: "example.\(name)",
            bundlePath: "/Applications/\(name).app",
            currentProcessID: 1, currentBundleIdentifier: "com.blitzreels.BlitzClean"
          )) != nil)
    }
    #expect(
      MemoryAppProtection.reason(
        .init(
          processID: 100, bundleIdentifier: nil, bundlePath: "/Applications/Example.app",
          currentProcessID: 1, currentBundleIdentifier: nil
        )) == nil)
  }

  @Test
  func incidentHistoryIsBoundedAndSurvivesRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    var history = MemoryIncidentHistory()
    for second in 0..<1_500 { history.append(event(second)) }
    #expect(history.events.count == MemoryIncidentHistory.capacity)
    let store = MemoryIncidentStore(url: url)
    try await store.save(history)
    let reloaded = await MemoryIncidentStore(url: url).load()
    #expect(reloaded.events.map(\.id) == history.events.map(\.id))
    history.append(event(100_000))
    #expect(history.events.count == 1)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test
  func corruptHistoryDoesNotPreventMonitoring() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    try Data("invalid".utf8).write(to: url)
    #expect(await MemoryIncidentStore(url: url).load().events.isEmpty)
  }

  private struct SampleInput {
    let seconds: Int
    let pressure: MemoryPressureLevel
    let swapOutMiB: UInt64
  }

  private func sample(_ input: SampleInput) -> MemoryGuardSample {
    MemoryGuardSample(
      date: Date(timeIntervalSince1970: Double(input.seconds)), pressure: input.pressure,
      available: gib, total: 36 * gib, compressed: 10 * gib, swapUsed: 13 * gib,
      swapOutBytes: input.swapOutMiB * 1_024 * 1_024
    )
  }

  private struct AppInput {
    let id: Int32
    let name: String
    let bytes: UInt64
    let protected: String?
    let active: Bool
  }

  private func app(_ input: AppInput) -> MemoryApp {
    MemoryApp(
      processID: input.id, name: input.name, bundleIdentifier: "example.\(input.name)",
      bundleURL: URL(fileURLWithPath: "/Applications/\(input.name).app"), memoryBytes: input.bytes,
      protectionReason: input.protected, isActive: input.active,
      launchDate: Date(timeIntervalSince1970: 1), childProcessCount: 2
    )
  }

  private struct DescriptorInput {
    let app: MemoryApp
    let active: Bool
    let launchDate: Date?
    let protected: String?
  }

  private func descriptor(_ input: DescriptorInput) -> MemoryAppDescriptor {
    MemoryAppDescriptor(
      processID: input.app.id, name: input.app.name, bundleIdentifier: input.app.bundleIdentifier,
      bundleURL: input.app.bundleURL, protectionReason: input.protected, isActive: input.active,
      launchDate: input.launchDate
    )
  }

  private func event(_ second: Int) -> MemoryIncident {
    MemoryIncident(
      id: UUID(), date: Date(timeIntervalSince1970: Double(second)), kind: "sample",
      detail: "Normal", sample: nil, apps: []
    )
  }
}
