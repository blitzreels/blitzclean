import AppKit
import SwiftUI

struct BlitzTrayView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var updates: AppUpdateController
  @Environment(\.openWindow) private var openWindow
  @AppStorage(MenuBarPreferenceKey.memoryDisplay) private var memoryDisplay = MenuBarMemoryDisplay
    .available

  private var snapshot: SystemSnapshot { monitor.snapshot }

  private var vitals: [MacVital] {
    MacVital.all(
      .init(snapshot: snapshot, memoryDisplay: memoryDisplay, memoryTone: memory.pressure.tone))
  }

  var body: some View {
    let topApps = memory.apps.largest(.init(count: 3, key: \.memoryBytes))
    VStack(spacing: 0) {
      header
      VStack(spacing: 10) {
        if memory.capacity.risk > .normal { pressureAlert }
        vitalsCard
        activityCard
        if !topApps.isEmpty { topAppsList(topApps) }
      }.padding(.horizontal, 12).padding(.bottom, 12)
      Rectangle().fill(BlitzUI.separator).frame(height: 1)
      footer
    }
    .frame(width: 340)
    .blitzTheme().blitzDropdownHost()
  }

  private var header: some View {
    HStack(spacing: 8) {
      BrandMark().frame(width: 40, height: 40).scaleEffect(0.55).frame(width: 22, height: 22)
      Text(AppBrand.name).font(BlitzType.section)
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
    }.padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
  }

  private var pressureAlert: some View {
    let capacity = memory.capacity
    let isDisk = capacity.limit == .disk
    return Button {
      navigation.review(capacity)
      openWindow.dashboard()
    } label: {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
          .foregroundStyle(capacity.risk.tone.color)
        VStack(alignment: .leading, spacing: 2) {
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
        BlitzChevron()
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .blitzToneCard(capacity.risk.tone, radius: 14)
    }.buttonStyle(BlitzCardButtonStyle()).help(capacity.reviewTitle)
  }

  private var vitalsCard: some View {
    HStack(spacing: 14) {
      BlitzVitalRings(vitals: vitals, lineWidth: 6) { EmptyView() }
        .frame(width: 92, height: 92)
      VStack(spacing: 2) {
        ForEach(vitals) { vital in
          Button {
            open(vital.page)
          } label: {
            HStack(spacing: 8) {
              Circle().fill(vital.color).frame(width: 7, height: 7)
              Text(vital.title).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
              Spacer(minLength: 4)
              Text(vital.compactValue).font(BlitzType.label).monospacedDigit().lineLimit(1)
                .foregroundStyle(
                  vital.alertColor ?? BlitzUI.primaryText
                )
                .contentTransition(.numericText())
              BlitzChevron()
            }.padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
          }.buttonStyle(BlitzRowButtonStyle(radius: 8)).help("Open \(vital.title)")
        }
      }
    }
    .padding(12)
    .blitzHeroCard()
  }

  private var activityCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      plotRow(
        title: "Memory", page: .memory,
        kind: memoryDisplay == .available ? .availableMemory : .memory, color: BlitzUI.mint)
      plotRow(title: "CPU", page: .cpu, kind: .cpu, color: CleanPage.cpu.hue)
    }.padding(.vertical, 10).padding(.horizontal, 4).blitzTable()
  }

  private func plotRow(title: String, page: CleanPage, kind: ResourceKind, color: Color)
    -> some View
  {
    Button {
      open(page)
    } label: {
      HStack(spacing: 10) {
        Text(title).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .frame(width: 50, alignment: .leading)
        ResourcePlot(samples: monitor.resourceSamples, kind: kind, color: color, seconds: 60)
          .frame(height: 26)
      }.padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
    }.buttonStyle(BlitzRowButtonStyle(radius: 8)).help("Open \(title)")
  }

  private func topAppsList(_ topApps: [MemoryApp]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      BlitzUI.sectionLabel("Using the most memory").padding(.horizontal, 8)
      ForEach(topApps) { app in
        Button {
          open(.memory)
        } label: {
          HStack(spacing: 10) {
            ApplicationIcon(source: .file(app.bundleURL.path), size: 22, fallback: "app")
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(app.name).font(BlitzType.body).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(ByteText.compact(app.memoryBytes)).font(BlitzType.numeric)
                  .foregroundStyle(BlitzUI.supportingText)
              }
              share(app)
            }
          }.padding(.horizontal, 8).frame(height: 40).contentShape(Rectangle())
        }.buttonStyle(BlitzRowButtonStyle(radius: 8)).help("Open Memory")
      }
    }.padding(.vertical, 10).padding(.horizontal, 4).blitzTable()
  }

  private func share(_ app: MemoryApp) -> some View {
    let ratio =
      snapshot.ramTotal > 0 ? min(1, Double(app.memoryBytes) / Double(snapshot.ramTotal)) : 0
    return GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.06))
        Capsule().fill(BlitzUI.mint.opacity(0.8)).frame(width: max(3, proxy.size.width * ratio))
      }
    }.frame(height: 3).accessibilityHidden(true)
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
      }.blitzButton(.accent).controlSize(.regular)
    }.padding(12)
  }

  private func open(_ page: CleanPage) {
    navigation.page = page
    openWindow.dashboard()
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
  @AppStorage(DockIconPreference.key) private var showsDockIcon = DockIconPreference.defaultValue

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
        VStack(alignment: .leading, spacing: 12) {
          Toggle(
            "Launch at login",
            isOn: Binding(get: { launchAtLogin.enabled }, set: { launchAtLogin.setEnabled($0) }))
          BlitzRowDivider(leading: 0)
          VStack(alignment: .leading, spacing: 4) {
            Toggle("Show Dock icon", isOn: $showsDockIcon)
              .onChange(of: showsDockIcon) { _, _ in
                NSApp.setActivationPolicy(DockIconPreference.policy())
              }
            Text("Only while the window is open. The menu bar icon stays.")
              .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          }
        }.panelCard(padding: 16)
        MemoryGuardControls(model: memory)
        projectFolders
        updatesSection
        familySection
      }.font(BlitzType.callout).toggleStyle(BlitzSwitchStyle())
        .frame(maxWidth: .infinity, alignment: .leading).padding(BlitzUI.pagePadding)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
