import AppKit
import Carbon
import SwiftUI
import Testing

@testable import BlitzClean

struct AppQuitPolicyTests {
  @Test func ordinaryQuitKeepsMonitoringButExplicitStopExits() {
    #expect(AppQuitPolicy.keepsMonitoring(.init(explicitStop: false, event: nil)))
    #expect(!AppQuitPolicy.keepsMonitoring(.init(explicitStop: true, event: nil)))
    let event = quitEvent()
    #expect(AppQuitPolicy.keepsMonitoring(.init(explicitStop: false, event: event)))
  }

  @Test func logoutRestartAndShutdownNeverStayResident() {
    for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut] {
      let event = quitEvent()
      event.setParam(
        NSAppleEventDescriptor(enumCode: OSType(reason)), forKeyword: AEKeyword(kAEQuitReason))
      #expect(!AppQuitPolicy.keepsMonitoring(.init(explicitStop: false, event: event)))
      let attributed = quitEvent()
      attributed.setAttribute(
        NSAppleEventDescriptor(enumCode: OSType(reason)), forKeyword: AEKeyword(kAEQuitReason))
      #expect(!AppQuitPolicy.keepsMonitoring(.init(explicitStop: false, event: attributed)))
    }
  }

  private func quitEvent() -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
  }
}

@MainActor
struct MenuBarMonitoringTests {
  private var snapshot: SystemSnapshot {
    .init(
      .init(
        diskAvailable: 120_000_000_000, diskTotal: 500_000_000_000,
        ramAvailable: 3_000_000_000, ramTotal: 16_000_000_000, memoryPressure: .normal,
        cpuUsage: 1, thermalStatus: .nominal, updatedAt: .now))
  }

  @Test func memoryModesDistinguishAvailableFromUsedAndUnknown() {
    #expect(MenuBarMemoryDisplay.available.menuValue(snapshot) == "3 GB free")
    #expect(MenuBarMemoryDisplay.used.menuValue(snapshot) == "13 GB used")
    #expect(MenuBarMemoryDisplay.percentage.menuValue(snapshot) == "81%")
    for display in MenuBarMemoryDisplay.allCases {
      #expect(display.menuValue(.empty) == "—")
      let text = MenuBarStatusText.make(
        .init(
          snapshot: snapshot, showDisk: false, showCPU: false, showMemory: true,
          memoryDisplay: display))
      #expect(text == "RAM \(display.menuValue(snapshot))")
    }
  }

  @Test func allMemoryModesFitAndRenderWhenRequested() throws {
    for display in MenuBarMemoryDisplay.allCases {
      let metrics = MenuBarMetrics(
        snapshot: snapshot, risk: .normal, showHealth: true, showCPU: true,
        showMemory: true, showDisk: true, memoryDisplay: display)
      let image = MenuBarLabelRenderer.image(content: metrics, colored: true)
      #expect(image.size.width > 100)
      #expect(image.size.width <= 260)
      #expect(image.size.height <= 24)
      if let path = ProcessInfo.processInfo.environment["BLITZ_TRAY_RENDER_DIR"] {
        let renderer = ImageRenderer(
          content: metrics.padding(8).background(.black).environment(\.colorScheme, .dark))
        renderer.scale = 3
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: URL(fileURLWithPath: path).appendingPathComponent("menu-\(display.rawValue).png"))
      }
    }
  }

  @Test func availableMemoryHistoryFallsAsUsedMemoryRises() {
    let low = ResourceSample(date: .now, cpu: nil, memory: 0.25)
    let high = ResourceSample(date: .now, cpu: nil, memory: 0.75)
    #expect(ResourceKind.availableMemory.value(low) == 0.75)
    #expect(ResourceKind.availableMemory.value(high) == 0.25)
    #expect(ResourceKind.memory.value(high) == 0.75)
    #expect(ResourceKind.cpu.value(high) == nil)
  }
}
