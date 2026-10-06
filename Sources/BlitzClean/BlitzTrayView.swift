import AppKit
import SwiftUI

struct BlitzTrayView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var navigation: CleanNavigation
  @Environment(\.openWindow) private var openWindow
  @AppStorage(MenuBarPreferenceKey.memoryDisplay) private var memoryDisplay = MenuBarMemoryDisplay
    .available

  private var snapshot: SystemSnapshot { monitor.snapshot }

  private var memoryDetail: String {
    guard snapshot.ramTotal > 0 else { return "Reading memory…" }
    return memoryDisplay == .available
      ? "\(ByteText.compact(snapshot.ramUsed)) used of \(ByteText.compact(snapshot.ramTotal))"
      : "\(ByteText.compact(snapshot.ramAvailable)) available"
  }

  var body: some View {
    let topApps = memory.apps.largest(.init(count: 3, key: \.memoryBytes))
    VStack(spacing: 0) {
      header
      VStack(spacing: 12) {
        if memory.capacity.risk > .normal { pressureAlert }
        memoryTile
        HStack(spacing: 12) {
          cpuTile
          storageTile
        }
        if !topApps.isEmpty { topAppsList(topApps) }
      }.padding(.horizontal, 14).padding(.bottom, 14)
      Rectangle().fill(BlitzUI.separator).frame(height: 1)
      footer
    }.frame(width: 340).blitzTheme().blitzDropdownHost()
  }

  private var header: some View {
    HStack(spacing: 8) {
      BrandMark().frame(width: 40, height: 40).scaleEffect(0.55).frame(width: 22, height: 22)
      Text(AppBrand.name).font(BlitzType.section)
      Spacer()
      BlitzActionMenu(label: "BlitzClean settings", symbol: "gearshape") {
        Button("Settings…") { open(.settings) }
        Divider()
        Button("Stop monitoring and quit") { AppLifetime.stopMonitoringAndQuit() }
      }
    }.padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
  }

  private var pressureAlert: some View {
    let capacity = memory.capacity
    let isDisk = capacity.limit == .disk
    return Button {
      navigation.review(capacity)
      openWindow.dashboard()
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
          .foregroundStyle(capacity.risk.tone.color).padding(.top, 1)
        VStack(alignment: .leading, spacing: 3) {
          Text(capacity.title).font(BlitzType.label)
          Text(
            isDisk
              ? "Avoid large downloads and builds. Free up space."
              : "Avoid new threads or builds. Pause or quit unused projects."
          )
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
        BlitzChevron().padding(.top, 3)
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .blitzToneCard(capacity.risk.tone)
    }.buttonStyle(BlitzCardButtonStyle()).help(capacity.reviewTitle)
  }

  private var memoryTile: some View {
    TrayTile(title: "Memory", page: .memory, navigation: navigation) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(memoryDisplay.value(snapshot)).font(.system(size: 26, weight: .semibold))
          .monospacedDigit().contentTransition(.numericText())
        Text(memoryDisplay == .available ? "available" : "used")
          .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
        Spacer(minLength: 0)
        if memory.pressure == .warning || memory.pressure == .critical {
          BlitzStatusBadge(
            title: memory.pressure == .critical ? "Critical pressure" : "High pressure",
            tone: memory.pressure == .critical ? .critical : .warning)
        }
      }
      ResourcePlot(
        samples: monitor.resourceSamples,
        kind: memoryDisplay == .available ? .availableMemory : .memory,
        color: BlitzUI.mint, seconds: 60
      ).frame(height: 34)
      Text(memoryDetail).font(BlitzType.caption).monospacedDigit()
        .foregroundStyle(BlitzUI.secondaryText)
    }
  }

  private var cpuTile: some View {
    TrayTile(title: "CPU", page: .cpu, navigation: navigation) {
      Text(snapshot.cpuUsage.map(PercentText.make) ?? "—")
        .font(.system(size: 20, weight: .semibold)).monospacedDigit()
        .contentTransition(.numericText())
      ResourcePlot(samples: monitor.resourceSamples, kind: .cpu, color: BlitzUI.mint, seconds: 60)
        .frame(height: 22)
    }
  }

  private var storageTile: some View {
    TrayTile(title: "Storage", page: .storage, navigation: navigation) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(ByteText.compact(snapshot.diskAvailable))
          .font(.system(size: 20, weight: .semibold)).monospacedDigit()
        Text("free").font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      CapacityBar(
        usedRatio: snapshot.diskUsedRatio, tone: MenuBarTones.disk(snapshot)
      ).frame(height: 22, alignment: .bottom)
    }
  }

  private func topAppsList(_ topApps: [MemoryApp]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      BlitzUI.sectionLabel("Using the most memory").padding(.horizontal, 2)
      VStack(spacing: 0) {
        ForEach(topApps) { app in
          Button {
            open(.memory)
          } label: {
            HStack(spacing: 10) {
              ApplicationIcon(source: .file(app.bundleURL.path), size: 20, fallback: "app")
              Text(app.name).font(BlitzType.body).lineLimit(1).truncationMode(.tail)
              Spacer(minLength: 8)
              Text(ByteText.compact(app.memoryBytes)).font(BlitzType.numeric)
                .foregroundStyle(BlitzUI.supportingText)
            }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
          }.buttonStyle(BlitzRowButtonStyle(radius: 8)).help("Open Memory")
        }
      }.padding(4).blitzTable()
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button {
        open(.recovery)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "waveform.path.ecg")
          Text("Revive apps")
          if recovery.attentionCount > 0 {
            BlitzCountBadge(
              count: recovery.attentionCount,
              label: "\(recovery.attentionCount) apps need attention")
          }
        }.frame(maxWidth: .infinity)
      }.blitzButton(.secondary).controlSize(.regular)
      Button {
        open(.overview)
      } label: {
        Text("Open dashboard").frame(maxWidth: .infinity)
      }.blitzButton(.emphasized).controlSize(.regular)
    }.padding(14)
  }

  private func open(_ page: CleanPage) {
    navigation.page = page
    openWindow.dashboard()
  }
}

private struct TrayTile<Content: View>: View {
  let title: String
  let page: CleanPage
  @ObservedObject var navigation: CleanNavigation
  @ViewBuilder let content: () -> Content
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      navigation.page = page
      openWindow.dashboard()
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(title).font(BlitzType.captionEmphasis).foregroundStyle(BlitzUI.secondaryText)
          Spacer()
          BlitzChevron()
        }
        content()
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .blitzTable()
    }.buttonStyle(BlitzCardButtonStyle()).help("Open \(title)")
  }
}

struct BlitzSettingsView: View {
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var launchAtLogin: LaunchAtLoginController
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var permissions: PermissionsModel
  @State private var roots = DeveloperLocations.additionalProjectRoots

  private var projectFolders: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Project folders").font(BlitzType.section)
          Text("Home folders are always scanned. Add projects that live elsewhere.")
            .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
        }
        Spacer()
        Button("Add folder…") { addRoot() }.blitzButton(.secondary).controlSize(.small)
      }
      ForEach(roots, id: \.self) { root in
        HStack {
          Text(root).font(BlitzType.body).lineLimit(1).truncationMode(.middle).help(root)
          Spacer()
          Button("Remove") { setRoots(roots.filter { $0 != root }) }
            .blitzButton(.quiet).controlSize(.small)
        }
      }
    }.panelCard(padding: 16)
  }

  private func addRoot() {
    guard let path = Finder.chooseFolder(), !roots.contains(path) else { return }
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
        PermissionSetupSection(memory: memory, recovery: recovery, permissions: permissions)
        VStack(alignment: .leading, spacing: 16) {
          Text("Show in menu bar").font(BlitzType.section)
          MenuBarDisplayControls()
          Text(
            "Closing the window or pressing ⌘Q keeps monitoring. To exit, choose Stop monitoring and quit from the menu bar’s gear menu."
          )
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
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
            .font(BlitzType.rowTitle)
          Text("Open source under MIT. Metrics and cleanup history stay on your Mac.")
            .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
          Link("Source code and issues", destination: AppBrand.repositoryURL)
        }
      }.font(BlitzType.callout).toggleStyle(BlitzSwitchStyle())
        .frame(maxWidth: .infinity, alignment: .leading).padding(BlitzUI.pagePadding)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
