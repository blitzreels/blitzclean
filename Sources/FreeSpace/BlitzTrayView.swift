import AppKit
import SwiftUI

struct BlitzTrayView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var navigation: CleanNavigation
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        BrandMark().scaleEffect(0.8).frame(width: 32, height: 32)
        Text(AppBrand.name).font(.system(size: 13, weight: .semibold))
        Spacer()
        BlitzActionMenu(label: "BlitzClean settings", symbol: "gearshape") {
          Button("Settings…") { open(.settings) }
          Divider()
          Button("Quit BlitzClean") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
      }.padding(16)
      Divider()
      VStack(spacing: 16) {
        if max(memory.risk, memory.capacity.risk) > .normal {
          Button("Avoid new threads · Review projects") { open(.projects) }
            .foregroundStyle(.orange).font(.callout)
        }
        HStack(spacing: 12) {
          trayMetric(
            .init(
              title: "CPU", value: monitor.snapshot.cpuUsage.map(PercentText.make) ?? "—",
              kind: .cpu, color: BlitzUI.mint, page: .cpu))
          trayMetric(
            .init(
              title: "RAM",
              value: monitor.snapshot.ramTotal > 0
                ? PercentText.make(monitor.snapshot.ramUsedRatio) : "—",
              kind: .memory, color: AppBrand.accent, page: .memory))
        }
        HStack {
          Text("Pressure: \(memory.pressure.title.lowercased())").font(.caption)
            .foregroundStyle(memory.pressure.tone.color)
          Spacer()
          Text("\(ByteText.compact(monitor.snapshot.ramAvailable)) available").font(.caption)
            .monospacedDigit().foregroundStyle(.secondary)
        }
        Divider()
        Button {
          open(.storage)
        } label: {
          VStack(spacing: 12) {
            HStack {
              Text("Storage").font(.system(size: 13, weight: .medium))
              Spacer()
              Text("\(ByteText.full(monitor.snapshot.diskAvailable)) free")
                .font(.system(size: 13)).monospacedDigit()
              Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            CapacityBar(
              usedRatio: 1 - Double(monitor.snapshot.diskAvailable)
                / Double(max(1, monitor.snapshot.diskTotal)),
              tone: MenuBarTones.disk(monitor.snapshot))
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).help("Review storage")
      }.padding(16)
      Divider()
      Button {
        open(.recovery)
      } label: {
        HStack {
          Label("Revive apps", systemImage: "waveform.path.ecg")
          Spacer()
          Image(systemName: "arrow.up.right")
        }.font(.system(size: 13, weight: .medium)).padding(16).contentShape(Rectangle())
      }.buttonStyle(.plain)
      Divider()
      Button {
        open(.overview)
      } label: {
        HStack {
          Text("Open dashboard").font(.system(size: 12, weight: .medium))
          Spacer()
          Image(systemName: "arrow.up.right.square")
        }.padding(16).contentShape(Rectangle())
      }.buttonStyle(.plain)
    }.frame(width: 340).blitzTheme().blitzDropdownHost()
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
  @ObservedObject var storage: StorageBreakdownModel
  @State private var roots = DeveloperLocations.additionalProjectRoots

  private var projectFolders: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Project folders").font(.system(size: 13, weight: .semibold))
          Text("Home folders are always scanned. Add projects that live elsewhere.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Add folder…") { addRoot() }.blitzButton(.secondary).controlSize(.small)
      }
      ForEach(roots, id: \.self) { root in
        HStack {
          Text(root).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
          Spacer()
          Button("Remove") { setRoots(roots.filter { $0 != root }) }
            .blitzButton(.quiet).controlSize(.small)
        }
      }
    }.panelCard(padding: 16)
  }

  private func addRoot() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let path = panel.url?.path, !roots.contains(path) else { return }
    setRoots(roots + [path])
  }

  private func setRoots(_ value: [String]) {
    roots = value
    UserDefaults.standard.set(value, forKey: "locations.projectRoots")
    if !storage.isScanning { storage.scan() }
  }

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
        projectFolders
        VStack(alignment: .leading, spacing: 8) {
          Text("BlitzClean \(AppBrand.version) · by BlitzReels")
            .font(.system(size: 13, weight: .medium))
          Text("Open source under MIT. Metrics and cleanup history stay on your Mac.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
          Link("Source code and issues", destination: AppBrand.repositoryURL)
        }
      }.font(.system(size: 13)).toggleStyle(BlitzSwitchStyle())
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
