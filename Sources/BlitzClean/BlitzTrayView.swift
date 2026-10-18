import AppKit
import SwiftUI

struct BlitzTrayView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var updates: AppUpdateController
  @ObservedObject var processes: DevProcessModel
  @Environment(\.openWindow) private var openWindow
  @AppStorage(MenuBarPreferenceKey.memoryDisplay) private var memoryDisplay = MenuBarMemoryDisplay
    .available

  private var snapshot: SystemSnapshot { monitor.snapshot }
  private var commands: ConsumerCommands { .init(processes: processes, memory: memory) }

  private var vitals: [MacVital] {
    MacVital.all(
      .init(snapshot: snapshot, memoryDisplay: memoryDisplay, memoryTone: memory.pressure.tone))
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      VStack(alignment: .leading, spacing: 14) {
        if memory.capacity.risk > .normal { issueRow }
        resources
        if let fix { fixRow(fix) }
        topConsumers
      }.padding(.horizontal, 12).padding(.bottom, 14)
      Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
      footer
    }
    .frame(width: 340)
    .background(BlitzUI.canvasBackground)
    .blitzTheme().blitzDropdownHost()
  }

  // MARK: Header

  private var header: some View {
    let attention = memory.capacity.risk > .normal || recovery.attentionCount > 0
    return HStack(spacing: 10) {
      BrandMark().frame(width: 40, height: 40).scaleEffect(0.55).frame(width: 22, height: 22)
      Text(AppBrand.name).font(.system(size: 13, weight: .semibold))
      HStack(spacing: 5) {
        BlitzStatusDot(tone: attention ? .warning : .good, diameter: 6)
        Text(attention ? "Needs attention" : "All good").font(BlitzType.caption)
          .foregroundStyle(BlitzUI.secondaryText)
      }
      Spacer()
      if updates.version != nil {
        Button(updates.actionTitle) { updates.check() }
          .blitzButton(.secondary).controlSize(.small).fixedSize()
          .help(updates.detail)
      }
      BlitzActionMenu(label: "BlitzClean settings", symbol: "gearshape") {
        Button("Settings…") { open(.settings) }
        if updates.version == nil {
          Button("Check for updates…") { updates.check() }.disabled(!updates.canCheck)
        }
        Divider()
        Text("More from BlitzReels").font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
          .padding(.horizontal, 10).padding(.top, 4)
        ForEach(AppBrand.family) { app in
          Button {
            NSWorkspace.shared.open(app.url)
          } label: {
            HStack {
              Text(app.name)
              Spacer()
              Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BlitzUI.tertiaryText)
            }
          }
        }
        Divider()
        Button("Stop monitoring and quit") { AppLifetime.stopMonitoringAndQuit() }
      }
    }.padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 10)
  }

  // MARK: Issue

  private var issueRow: some View {
    let capacity = memory.capacity
    let isDisk = capacity.limit == .disk
    return Button {
      navigation.review(capacity)
      openWindow.dashboard()
    } label: {
      HStack(spacing: 12) {
        BlitzColorTile(
          symbol: isDisk ? "internaldrive.fill" : "exclamationmark",
          color: capacity.risk.tone.color, size: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(capacity.title).font(BlitzType.rowTitle).foregroundStyle(BlitzUI.primaryText)
          Text(
            isDisk
              ? "Free up space before large downloads or builds."
              : "Quit what you are not using before starting new work."
          )
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      .padding(12).contentShape(Rectangle())
    }
    .buttonStyle(BlitzRowButtonStyle(radius: 12))
    .blitzCard(padding: 0)
    .help(capacity.reviewTitle)
  }

  // MARK: Resources

  private var resources: some View {
    VStack(alignment: .leading, spacing: 8) {
      BlitzGroupLabel(title: "Resources").padding(.leading, 4)
      VStack(spacing: 0) {
        ForEach(vitals) { vital in
          resourceRow(vital)
          if vital.id != vitals.last?.id { BlitzRowDivider(leading: 50) }
        }
      }.blitzCard(padding: 0)
    }
  }

  private func resourceRow(_ vital: MacVital) -> some View {
    Button {
      open(vital.page)
    } label: {
      HStack(spacing: 12) {
        BlitzColorTile(symbol: vital.page.tileSymbol, color: vital.page.color, size: 26)
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline) {
            Text(vital.title).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
            Spacer(minLength: 8)
            Text(vital.compactValue).font(BlitzNumberFont.value(15)).monospacedDigit()
              .foregroundStyle(vital.alertColor ?? BlitzUI.primaryText)
              .contentTransition(.numericText())
          }
          visual(vital.page)
        }
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      .padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
    }.buttonStyle(BlitzRowButtonStyle(radius: 0)).help("Open \(vital.title)")
  }

  @ViewBuilder private func visual(_ page: CleanPage) -> some View {
    switch page {
    case .cpu:
      ResourcePlot(
        samples: monitor.resourceSamples, kind: .cpu, color: page.color, seconds: 120
      ).frame(height: 20)
    case .memory:
      SegmentedBar(
        segments: [.init(id: "used", color: page.color, fraction: snapshot.ramUsedRatio)],
        height: 4)
    default:
      SegmentedBar(
        segments: [.init(id: "used", color: page.color, fraction: snapshot.diskUsedRatio)],
        height: 4)
    }
  }

  // MARK: Fix

  private struct Fix {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let actionTitle: String
    let actionSymbol: String
    let perform: () -> Void
  }

  /// The single most useful thing to do right now, done from the tray when it is safe to.
  private var fix: Fix? {
    let commands = commands
    if let busy = processes.consumers.filter({
      $0.canSignal && !$0.isPaused
        && processes.activity.busy(.init(id: $0.id, now: .now)) >= ConsumerActivity.runawayAfter
    }).max(by: { $0.cpuPercent < $1.cpuPercent }) {
      return Fix(
        title: busy.name, detail: "Using \(CPUText.cores(busy.cpuPercent)) for a while",
        symbol: "cpu.fill", color: BlitzPalette.cpu, actionTitle: "Pause",
        actionSymbol: "pause.fill",
        perform: { processes.signal(.init(consumer: busy, signal: .pause)) })
    }
    let idle = FreeMemoryPlan.idle(
      .init(
        consumers: processes.consumers, activity: processes.activity,
        quittableApps: commands.quittableApps, now: .now))
    let short = memory.capacity.risk >= .warning && memory.capacity.limit == .memory
    let target =
      idle.first
      ?? (short ? processes.consumers.first { commands.canStop($0) && !$0.isPaused } : nil)
    if let target {
      let idleFor = processes.activity.idle(.init(id: target.id, now: .now))
      let stopTitle = commands.stopTitle(target)
      return Fix(
        title: target.name,
        detail: idleFor >= ConsumerActivity.idleAfter
          ? "Idle \(ResourceLeadersSection.duration(idleFor)) · frees \(ByteText.compact(target.memoryBytes))"
          : "Frees \(ByteText.compact(target.memoryBytes)) of memory",
        symbol: "memorychip.fill", color: BlitzPalette.memory, actionTitle: stopTitle,
        actionSymbol: stopTitle == "Quit" ? "xmark" : "stop.fill",
        perform: { commands.stop(target) })
    }
    if memory.capacity.limit == .disk, memory.capacity.risk > .normal {
      return Fix(
        title: "Disk almost full", detail: "See what you can free on Overview",
        symbol: "internaldrive.fill", color: BlitzPalette.storage, actionTitle: "Free up space",
        actionSymbol: "sparkles", perform: { open(.overview) })
    }
    return nil
  }

  private func fixRow(_ fix: Fix) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      BlitzGroupLabel(title: "Suggested").padding(.leading, 4)
      HStack(spacing: 12) {
        BlitzColorTile(symbol: fix.symbol, color: fix.color, size: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text(fix.title).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
          Text(fix.detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Button(action: fix.perform) {
          Label(fix.actionTitle, systemImage: fix.actionSymbol)
        }.blitzButton(.accent).controlSize(.small).fixedSize()
      }.padding(12).blitzCard(padding: 0)
    }
  }

  // MARK: Top consumers

  @ViewBuilder private var topConsumers: some View {
    let top = Array(processes.consumers.filter { $0.kind != .system }.prefix(3))
    if !top.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        BlitzGroupLabel(title: "Using the most memory").padding(.leading, 4)
        VStack(spacing: 0) {
          ForEach(top) { consumer in
            TrayConsumerRow(
              consumer: consumer, commands: commands, total: snapshot.ramTotal,
              onOpen: { open(.memory) })
            if consumer.id != top.last?.id { BlitzRowDivider(leading: 46) }
          }
        }.blitzCard(padding: 0)
      }
    }
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 8) {
      Button {
        EmergencyControlsLauncher.open()
      } label: {
        Image(systemName: "lifepreserver").font(.system(size: 14, weight: .medium))
          .frame(width: 20)
      }.blitzButton(.secondary).help("Emergency controls · ⌃⌥⌘R")
        .accessibilityLabel("Emergency controls")
      Button {
        open(.recovery)
      } label: {
        HStack(spacing: 6) {
          Text("Revive apps")
          if recovery.attentionCount > 0 {
            BlitzCountBadge(
              count: recovery.attentionCount,
              label: "\(recovery.attentionCount) apps need attention")
          }
        }.frame(maxWidth: .infinity)
      }.blitzButton(.secondary)
      Button {
        open(.overview)
      } label: {
        Text("Open BlitzClean").frame(maxWidth: .infinity)
      }.blitzButton(fix == nil ? .accent : .secondary)
    }.controlSize(.regular).padding(12)
  }

  private func open(_ page: CleanPage) {
    if page == .storage { navigation.storagePage = .drive }
    navigation.page = page
    openWindow.dashboard()
  }
}

/// A memory user in the tray; its Stop or Quit button appears on hover.
private struct TrayConsumerRow: View {
  let consumer: ResourceConsumer
  let commands: ConsumerCommands
  let total: UInt64
  let onOpen: () -> Void
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 10) {
      Button(action: onOpen) {
        HStack(spacing: 10) {
          if consumer.kind == .workload, let directory = consumer.directory {
            ProjectIcon(directory: directory, processName: "", size: 22, fallbackSymbol: "terminal")
          } else {
            ApplicationIcon(source: .name(consumer.iconName), size: 22, fallback: "terminal")
          }
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(consumer.name).font(BlitzType.body).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(BlitzUI.primaryText)
              Spacer(minLength: 8)
              if !hovered || !commands.canStop(consumer) {
                Text(ByteText.compact(consumer.memoryBytes)).font(BlitzType.numeric)
                  .foregroundStyle(BlitzUI.supportingText)
              }
            }
            SegmentedBar(
              segments: [
                .init(
                  id: "share", color: BlitzPalette.memory,
                  fraction: total == 0 ? 0 : Double(consumer.memoryBytes) / Double(total))
              ], height: 3)
          }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).help("Open Memory")
      if hovered, commands.canStop(consumer) {
        Button(commands.stopTitle(consumer)) { commands.stop(consumer) }
          .blitzButton(.secondary).controlSize(.mini)
          .disabled(commands.isBusy(consumer))
      }
    }
    .padding(.horizontal, 12).frame(height: 46)
    .background(hovered ? Color.white.opacity(0.04) : .clear)
    .onHover { hovered = $0 }
  }
}

struct BlitzSettingsView: View {
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var launchAtLogin: LaunchAtLoginController
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var permissions: PermissionsModel
  @ObservedObject var updates: AppUpdateController
  @State private var roots = DeveloperLocations.additionalProjectRoots

  private var familySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 8) {
        Text("Our other apps").font(BlitzType.section)
        Spacer()
        if let wordmark = AppBrand.makerWordmark {
          Image(nsImage: wordmark).resizable().scaledToFit().frame(height: 13)
            .accessibilityLabel("BlitzReels")
        }
      }
      VStack(spacing: 0) {
        ForEach(AppBrand.family) { app in
          FamilyAppRow(app: app)
          if app.id != AppBrand.family.last?.id { BlitzRowDivider(leading: 56) }
        }
      }.padding(4).blitzTable()
      HStack(spacing: 6) {
        Text(
          "BlitzClean \(AppBrand.version) by BlitzReels. Open source under MIT; your data stays on your Mac."
        )
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        Link("Source code", destination: AppBrand.repositoryURL).buttonStyle(.plain)
          .font(BlitzType.caption).underline().foregroundStyle(BlitzUI.supportingText)
          .blitzPointingHand()
      }
    }
  }

  private var updatesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Updates").font(BlitzType.section)
          Text(updates.detail).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        HStack(spacing: 8) {
          if updates.status == .checking || updates.isWaitingForUpdater {
            ProgressView().controlSize(.small)
          }
          Button(updates.actionTitle) { updates.check() }
            .blitzButton(updates.version == nil ? .secondary : .accent).controlSize(.small)
            .disabled(!updates.canCheck)
        }
      }
      if updates.isAvailable {
        Toggle(
          "Check for updates automatically",
          isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
      }
    }.panelCard(padding: 16)
  }

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
    storage.scanCleanup()
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
        updatesSection
        familySection
      }.font(BlitzType.callout).toggleStyle(BlitzSwitchStyle())
        .frame(maxWidth: .infinity, alignment: .leading).padding(BlitzUI.pagePadding)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
