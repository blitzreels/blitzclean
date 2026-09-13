import AppKit
import SwiftUI

struct BlitzTrayView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var launchAtLogin: LaunchAtLoginController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        BrandMark().scaleEffect(0.8).frame(width: 32, height: 32)
        Text(AppBrand.name).font(.system(size: 13, weight: .semibold))
        Spacer()
        Menu {
          MenuBarDisplayMenuItems()
          Divider()
          Toggle(
            "Launch at login",
            isOn: Binding(get: { launchAtLogin.enabled }, set: { launchAtLogin.setEnabled($0) }))
          SettingsLink { Text("Settings…") }
          Divider()
          Button("Quit BlitzClean") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
          Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("BlitzClean settings")
      }.padding(16)
      Divider()
      VStack(spacing: 16) {
        HStack(spacing: 12) {
          trayMetric(
            .init(
              title: "CPU", value: monitor.snapshot.cpuUsage.map(PercentText.make) ?? "—",
              kind: .cpu, color: BlitzUI.mint, page: .cpu))
          trayMetric(
            .init(
              title: "Memory", value: ByteText.compact(monitor.snapshot.ramUsed),
              kind: .memory, color: AppBrand.accent, page: .memory))
        }
        HStack {
          Text("Pressure: \(memory.pressure.title.lowercased())").font(.caption)
            .foregroundStyle(memory.pressure.tone.color)
          Spacer()
          Text("\(ByteText.compact(monitor.snapshot.ramAvailable)) available").font(.caption)
            .monospacedDigit().foregroundStyle(.secondary)
        }
        Button("Free RAM…") { open(.memory) }
          .buttonStyle(BlitzButtonStyle(.secondary)).frame(
            maxWidth: .infinity, alignment: .trailing)
        Divider()
        HStack {
          Text("Storage").font(.system(size: 13, weight: .medium))
          Spacer()
          Text("\(ByteText.full(monitor.snapshot.diskAvailable)) free").font(.system(size: 13))
            .monospacedDigit()
        }
        CapacityBar(
          usedRatio: 1 - Double(monitor.snapshot.diskAvailable)
            / Double(max(1, monitor.snapshot.diskTotal)), tone: MenuBarTones.disk(monitor.snapshot))
        Button("Clean storage…") { open(.storage) }
          .buttonStyle(BlitzButtonStyle(.secondary)).frame(
            maxWidth: .infinity, alignment: .trailing)
      }.padding(16)
      Divider()
      Button {
        open(.overview)
      } label: {
        HStack {
          Text("Open BlitzClean").font(.system(size: 12, weight: .medium))
          Spacer()
          Image(systemName: "arrow.up.right.square")
        }.padding(16).contentShape(Rectangle())
      }.buttonStyle(.plain)
    }.frame(width: 360).blitzTheme()
  }

  private struct TrayMetricInput {
    let title: String
    let value: String
    let kind: ResourceKind
    let color: Color
    let page: CleanPage
  }

  private func trayMetric(_ input: TrayMetricInput) -> some View {
    Button {
      open(input.page)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        Text(input.title).font(.caption).foregroundStyle(.secondary)
        Text(input.value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
        ResourcePlot(
          samples: monitor.resourceSamples, kind: input.kind, color: input.color, seconds: 60
        )
        .frame(height: 36)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }.buttonStyle(.plain)
  }

  private func open(_ page: CleanPage) {
    navigation.page = page
    openWindow(id: "dashboard")
    NSApp.activate(ignoringOtherApps: true)
  }
}

struct BlitzSettingsView: View {
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var launchAtLogin: LaunchAtLoginController

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 16) {
          Text("Show in menu bar").font(.system(size: 13, weight: .semibold))
          MenuBarDisplayControls()
        }.panelCard(padding: 16)
        Toggle(
          "Launch at login",
          isOn: Binding(get: { launchAtLogin.enabled }, set: { launchAtLogin.setEnabled($0) })
        )
        .panelCard(padding: 16)
        MemoryGuardControls(model: memory)
        VStack(alignment: .leading, spacing: 8) {
          Text("BlitzClean \(AppBrand.version) · by BlitzReels")
            .font(.system(size: 13, weight: .medium))
          Text("Open source under MIT. Metrics and cleanup history stay on your Mac.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
          Link("Source code and issues", destination: AppBrand.repositoryURL)
        }
      }.font(.system(size: 13)).toggleStyle(BlitzSwitchStyle())
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }.frame(width: 560, height: 620).blitzTheme()
  }
}
