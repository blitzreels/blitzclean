import AppKit
import IOKit.ps

/// How often each background reader runs, decided in one place. Readers slow down together while another
/// app is in front and back off further under memory pressure, so BlitzClean never adds load to a Mac that is
/// already swapping. On battery they stretch the same way, so a window left open behind other apps doesn't
/// drain it. With no BlitzClean window on screen, only the menu bar figures keep their pace; the project,
/// memory and recovery scans wait a minute, since nobody is reading them. Pressure protection and the build
/// brake keep their own 2-second sampler, and the cleanup history sync stays at 3 seconds because it only
/// reads one small file.
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

  enum Visibility: Equatable {
    /// BlitzClean is the active app.
    case foreground
    /// A BlitzClean window is on screen behind another app.
    case background
    /// Only the menu bar item shows.
    case hidden
  }

  enum Power: Equatable {
    case adapter
    case battery
    /// Low Power Mode, on battery or not.
    case lowPower
  }

  struct Context: Equatable {
    let visibility: Visibility
    let pressure: MemoryRisk
    var power = Power.adapter
  }

  static func interval(_ reader: Reader, _ context: Context) -> TimeInterval {
    let base: (front: TimeInterval, back: TimeInterval, hidden: TimeInterval) =
      switch reader {
      case .system: (2, 6, 6)
      case .processes: (5, 15, 60)
      case .memoryScan: (15, 30, 60)
      case .recovery: (2, 6, 30)
      case .docker: (20, 60, 120)
      }
    let interval =
      switch context.visibility {
      case .foreground: base.front
      case .background: base.back
      case .hidden: base.hidden
      }
    let pressureFactor: TimeInterval =
      switch context.pressure {
      case .critical: 3
      case .warning: 2
      case .normal, .growing: 1
      }
    // The window someone is reading keeps its pace; power only stretches readers nobody is watching.
    let powerFactor: TimeInterval =
      switch (context.visibility, context.power) {
      case (.foreground, _), (_, .adapter): 1
      case (_, .battery): 2
      case (_, .lowPower): 3
      }
    return interval * max(pressureFactor, powerFactor)
  }

  /// Without an application (tests, `swift run`) there is no background to slow down for.
  @MainActor static var current: Context {
    .init(visibility: visibility, pressure: ResourceSnapshotCache.pressure.risk, power: power)
  }

  /// The menu bar item is a window too, so only windows taller than it count as something on screen.
  @MainActor static var visibility: Visibility {
    guard let app = NSApp else { return .foreground }
    if app.isActive { return .foreground }
    let shown = app.windows.contains {
      $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.height > 60
    }
    return shown ? .background : .hidden
  }

  static var power: Power {
    if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
    let source = IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo()?.takeRetainedValue())
    return source?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue ? .battery : .adapter
  }

  @MainActor static func interval(_ reader: Reader) -> TimeInterval {
    interval(reader, current)
  }
}
