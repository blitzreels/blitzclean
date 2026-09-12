import Foundation
import Testing

@testable import FreeSpace

struct DiskGuardTests {
  private let gib: UInt64 = 1_024 * 1_024 * 1_024

  private struct SampleInput {
    let seconds: Double
    let availableGiB: UInt64
    let swapGiB: UInt64
  }

  private func sample(_ input: SampleInput) -> DiskGuardSample {
    DiskGuardSample(
      date: Date(timeIntervalSince1970: input.seconds), available: input.availableGiB * gib,
      swapUsed: input.swapGiB * gib)
  }

  @Test
  func lowSpaceAlertsWorkEvenWhenMemoryPressureIsNormal() {
    var evaluator = DiskRiskEvaluator()
    #expect(
      evaluator.evaluate(sample(.init(seconds: 0, availableGiB: 50, swapGiB: 10))).risk == .normal)
    #expect(
      evaluator.evaluate(sample(.init(seconds: 5, availableGiB: 27, swapGiB: 10))).risk == .warning)
    #expect(
      evaluator.evaluate(sample(.init(seconds: 10, availableGiB: 15, swapGiB: 10))).risk
        == .critical)
    #expect(
      evaluator.evaluate(sample(.init(seconds: 15, availableGiB: 5, swapGiB: 10))).risk
        == .emergency)
  }

  @Test
  func rapidLossDoesNotAlertAboveThirtyGB() {
    var evaluator = DiskRiskEvaluator()
    _ = evaluator.evaluate(sample(.init(seconds: 0, availableGiB: 70, swapGiB: 10)))
    let result = evaluator.evaluate(sample(.init(seconds: 60, availableGiB: 60, swapGiB: 18)))
    #expect(result.risk == .normal)
    var gate = DiskAlertGate()
    let shouldSend = gate.shouldSend(result)
    #expect(!shouldSend)
    #expect(result.minutesToReserve == 5)
    #expect(result.lostBytes == 10 * gib)
    #expect(result.swapGrowth == 8 * gib)
  }

  @Test
  func thirtyDecimalGBIsHealthyAndOneByteLessWarns() {
    var evaluator = DiskRiskEvaluator()
    let healthy = evaluator.evaluate(
      DiskGuardSample(
        date: Date(timeIntervalSince1970: 0), available: 30_000_000_000, swapUsed: nil))
    let warning = evaluator.evaluate(
      DiskGuardSample(
        date: Date(timeIntervalSince1970: 5), available: 29_999_999_999, swapUsed: nil))
    #expect(healthy.risk == .normal)
    #expect(warning.risk == .warning)
    #expect(healthy.detail.contains("target 30 GB"))
  }

  @Test
  func rapidLossStillEscalatesBelowThirtyGB() {
    var evaluator = DiskRiskEvaluator()
    _ = evaluator.evaluate(sample(.init(seconds: 0, availableGiB: 35, swapGiB: 10)))
    let result = evaluator.evaluate(sample(.init(seconds: 60, availableGiB: 25, swapGiB: 18)))
    #expect(result.risk == .critical)
    #expect(result.minutesToReserve == 1.5)
  }

  @Test
  func oldSwapAndSpaceRecoveryAreNotOngoingGrowth() {
    var evaluator = DiskRiskEvaluator()
    _ = evaluator.evaluate(sample(.init(seconds: 0, availableGiB: 55, swapGiB: 30)))
    let result = evaluator.evaluate(sample(.init(seconds: 60, availableGiB: 65, swapGiB: 30)))
    #expect(result.risk == .normal)
    #expect(result.minutesToReserve == nil)
    #expect(result.lostBytes == 0)
    #expect(result.swapGrowth == 0)
  }

  @Test
  func sleepGapDoesNotInventADepletionRate() {
    var evaluator = DiskRiskEvaluator()
    _ = evaluator.evaluate(sample(.init(seconds: 0, availableGiB: 100, swapGiB: 1)))
    let result = evaluator.evaluate(sample(.init(seconds: 3_600, availableGiB: 20, swapGiB: 20)))
    #expect(result.risk == .warning)
    #expect(result.minutesToReserve == nil)
    #expect(result.lostBytes == 0)
  }

  @Test
  func escalationBypassesCooldownWithoutRepeatedNotifications() {
    var evaluator = DiskRiskEvaluator()
    var gate = DiskAlertGate()
    let inputs: [SampleInput] = [
      .init(seconds: 0, availableGiB: 25, swapGiB: 10),
      .init(seconds: 5, availableGiB: 24, swapGiB: 10),
      .init(seconds: 10, availableGiB: 14, swapGiB: 10),
      .init(seconds: 15, availableGiB: 4, swapGiB: 10),
      .init(seconds: 20, availableGiB: 3, swapGiB: 10),
      .init(seconds: 621, availableGiB: 3, swapGiB: 10),
    ]
    let decisions = inputs.map { gate.shouldSend(evaluator.evaluate(sample($0))) }
    #expect(decisions == [true, false, true, true, false, true])
  }
}
