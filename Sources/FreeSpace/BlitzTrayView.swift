import AppKit
import SwiftUI

struct BlitzTrayView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var cleanup: QuickCleanModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var launchAtLogin: LaunchAtLoginController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        BrandMark().scaleEffect(0.8).frame(width: 32, height: 32)
        VStack(alignment: .leading, spacing: 3) {
          Text(AppBrand.name).font(.headline)
          Text("by BlitzReels").font(.caption2).foregroundStyle(.secondary)
        }
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
              title: "RAM used", value: PercentText.make(monitor.snapshot.ramUsedRatio),
              kind: .memory, color: AppBrand.accent, page: .memory))
        }
        HStack {
          Circle().fill(memory.pressure.tone.color).frame(width: 7, height: 7)
          Text("Pressure: \(memory.pressure.title.lowercased())").font(.caption)
          Spacer()
          Text("\(ByteText.compact(monitor.snapshot.ramAvailable)) available").font(.caption)
            .monospacedDigit().foregroundStyle(.secondary)
        }
        HStack {
          Text("Swap \(memory.sample?.swapUsed.map(ByteText.compact) ?? "—")")
          Spacer()
          Text(
            "\(ByteText.compact(monitor.snapshot.ramUsed)) / \(ByteText.compact(monitor.snapshot.ramTotal)) RAM"
          )
        }.font(.caption2).foregroundStyle(.secondary)
        Button {
          open(.memory)
        } label: {
          Label("Free RAM…", systemImage: "memorychip").frame(maxWidth: .infinity)
        }.buttonStyle(BlitzButtonStyle(.accent)).controlSize(.large)
        Divider()
        HStack {
          Label("Disk free", systemImage: "internaldrive").font(.callout)
          Spacer()
          Text(ByteText.full(monitor.snapshot.diskAvailable)).font(.title3.weight(.semibold))
            .monospacedDigit()
        }
        CapacityBar(
          usedRatio: 1 - Double(monitor.snapshot.diskAvailable)
            / Double(max(1, monitor.snapshot.diskTotal)), tone: MenuBarTones.disk(monitor.snapshot))
        HStack {
          Text(
            cleanup.scannedAt == nil
              ? "Find files you can remove"
              : "\(ByteText.compact(cleanup.totalBytes)) caches to review"
          )
          .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Clean storage…") { open(.cleanup) }.buttonStyle(BlitzButtonStyle(.secondary))
        }
      }.padding(16)
      Divider()
      Button {
        open(.overview)
      } label: {
        HStack {
          Text("Open BlitzClean").font(.callout.weight(.semibold))
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
      }.frame(maxWidth: .infinity, alignment: .leading).panelCard(padding: 12)
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
    Form {
      Section("Menu bar") { MenuBarDisplayMenuItems() }
      Section("Startup") {
        Toggle(
          "Launch at login",
          isOn: Binding(get: { launchAtLogin.enabled }, set: { launchAtLogin.setEnabled($0) }))
      }
      Section("Alerts") { MemoryGuardControls(model: memory) }
      Section("About BlitzClean") {
        Text("BlitzClean 1.0 · by BlitzReels").font(.headline)
        Text("Open source under the MIT license. Metrics and cleanup history stay on your Mac.")
        Link("Source code and issues", destination: AppBrand.repositoryURL)
      }
    }.formStyle(.grouped).padding(10).frame(width: 560, height: 580).blitzTheme()
  }
}
