import AppKit

/// How often each background reader runs, decided in one place. Readers slow down together while another
/// app is in front and back off further under memory pressure, so BlitzClean never adds load to a Mac that is
/// already swapping. Pressure protection keeps its own 2-second sampler, and the cleanup history sync stays
/// at 3 seconds because it only reads one small file.
enum RefreshCadence {
  enum Reader: CaseIterable {
    /// CPU, memory and disk totals for the menu bar and sidebar.
    case system
    /// Process, AI session and project scan (`ps`, `lsof`).
    case processes
    /// Per-app memory footprints.
    case memoryScan
    /// Process states and hang flags on Revive apps.
    case recovery
    /// Docker containers on Projects.
    case docker
  }

  struct Context: Equatable {
    let foreground: Bool
    let pressure: MemoryRisk
  }

  static func interval(_ reader: Reader, _ context: Context) -> TimeInterval {
    let base: (front: TimeInterval, back: TimeInterval) =
      switch reader {
      case .system: (2, 6)
      case .processes: (5, 15)
      case .memoryScan: (15, 30)
      case .recovery: (2, 6)
      case .docker: (20, 60)
      }
    let interval = context.foreground ? base.front : base.back
    switch context.pressure {
    case .critical: return interval * 3
    case .warning: return interval * 2
    case .normal, .growing: return interval
    }
  }

  /// Without an application (tests, `swift run`) there is no background to slow down for.
  @MainActor static var current: Context {
    .init(
      foreground: NSApp.map(\.isActive) ?? true, pressure: ResourceSnapshotCache.pressure.risk)
  }

  @MainActor static func interval(_ reader: Reader) -> TimeInterval {
    interval(reader, current)
  }
}
