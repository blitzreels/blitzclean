import Foundation

/// Free disk and memory read right before and right after an action, so the result states what changed
/// rather than the size the action was expected to free.
struct ResourceReading: Equatable, Sendable {
  let diskFree: UInt64
  let memoryFree: UInt64

  static func now() -> Self {
    .init(
      diskFree: CleanupVolume.read(NSHomeDirectory())?.available ?? 0,
      memoryFree: VMMemoryStatsReader.current()?.available ?? 0)
  }

  /// macOS returns freed memory and disk blocks over a second or two, so the after reading waits first.
  static func settled() async -> Self {
    try? await Task.sleep(for: .seconds(2))
    return now()
  }
}

enum MeasuredResult {
  struct Change {
    let before: ResourceReading
    let after: ResourceReading
  }

  /// Changes smaller than this are noise from other apps.
  static let noticeable: UInt64 = 100_000_000

  static func disk(_ change: Change) -> String {
    line(
      .init(noun: "Free disk space", before: change.before.diskFree, after: change.after.diskFree))
  }

  static func memory(_ change: Change) -> String {
    line(
      .init(noun: "Free memory", before: change.before.memoryFree, after: change.after.memoryFree))
  }

  private struct Line {
    let noun: String
    let before: UInt64
    let after: UInt64
  }

  private static func line(_ input: Line) -> String {
    let rise = input.after > input.before ? input.after - input.before : 0
    guard rise >= noticeable else {
      return
        "\(input.noun) is still \(ByteText.compact(input.after)); other apps may be using what was freed."
    }
    return
      "\(input.noun) went from \(ByteText.compact(input.before)) to \(ByteText.compact(input.after))."
  }
}
