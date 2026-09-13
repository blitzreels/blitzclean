import AppKit
import SwiftUI

enum CleanPage: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case memory = "Memory"
  case cpu = "CPU"
  case storage = "Storage"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .memory: "memorychip"
    case .cpu: "cpu"
    case .storage: "internaldrive"
    }
  }
}

enum CleanStoragePage: String, CaseIterable {
  case caches = "Caches"
  case files = "Large files"
  case dependencies = "Dependencies"
}

@MainActor
final class CleanNavigation: ObservableObject {
  @Published var page = CleanPage.overview
  @Published var storagePage = CleanStoragePage.caches
}

struct BlitzDashboardView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var cleanup: QuickCleanModel
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var developerBrowser: DeveloperBrowserModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var workspaces: WorkspaceController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          BrandMark().frame(width: 32, height: 32)
          Text(AppBrand.name).font(.system(size: 15, weight: .semibold))
        }.padding(20)
        VStack(spacing: 4) {
          ForEach(CleanPage.allCases) { page in
            Button {
              navigation.page = page
            } label: {
              Label(page.rawValue, systemImage: page.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).frame(height: 38)
            }
            .buttonStyle(BlitzSelectionButtonStyle(isSelected: navigation.page == page))
            .accessibilityValue(navigation.page == page ? "Selected" : "")
          }
        }.padding(.horizontal, 12)
        Spacer()
        VStack(alignment: .leading, spacing: 4) {
          Button("Developer tools", systemImage: "terminal") { openWindow(id: "workspace") }
          SettingsLink { Label("Settings", systemImage: "gearshape") }
        }.buttonStyle(BlitzButtonStyle(.quiet)).padding(12)
      }.background(BlitzUI.sidebarBackground)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
    } detail: {
      Group {
        switch navigation.page {
        case .overview: overview
        case .memory: MemoryControlView(monitor: monitor, model: memory)
        case .cpu: CPUControlView(monitor: monitor)
        case .storage:
          BlitzStorageView(
            monitor: monitor, cleanup: cleanup, storage: storage, navigation: navigation,
            developerBrowser: developerBrowser, processes: processes, workspaces: workspaces)
        }
      }
      .navigationTitle(navigation.page.rawValue)
    }
    .blitzTheme()
    .frame(minWidth: 900, minHeight: 620)
    .task {
      monitor.refresh()
      memory.refresh()
    }
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 16) {
          ResourceCard(
            title: "Memory", value: ByteText.compact(monitor.snapshot.ramUsed),
            detail: "of \(ByteText.compact(monitor.snapshot.ramTotal)) used",
            samples: monitor.resourceSamples, kind: .memory,
            action: { navigation.page = .memory })
          ResourceCard(
            title: "CPU", value: monitor.snapshot.cpuUsage.map(PercentText.make) ?? "—",
            detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
            samples: monitor.resourceSamples, kind: .cpu,
            action: { navigation.page = .cpu })
        }
        HStack(spacing: 24) {
          VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
              Text("Storage").font(.system(size: 13, weight: .semibold))
              Spacer()
              Text(
                "\(ByteText.full(monitor.snapshot.diskAvailable)) free of \(ByteText.full(monitor.snapshot.diskTotal))"
              )
              .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            CapacityBar(
              usedRatio: 1 - Double(monitor.snapshot.diskAvailable)
                / Double(max(1, monitor.snapshot.diskTotal)),
              tone: MenuBarTones.disk(monitor.snapshot))
          }
          Button("Clean storage…") { navigation.page = .storage }
            .buttonStyle(BlitzButtonStyle(.accent))
        }.panelCard(padding: 20)
        VStack(spacing: 0) {
          HStack {
            Text("Apps using the most memory").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Free RAM…") { navigation.page = .memory }
              .buttonStyle(BlitzButtonStyle(.secondary))
          }.padding(.bottom, 12)
          ForEach(memory.apps.prefix(4)) { app in
            HStack(spacing: 10) {
              AppMemoryIcon(app: app)
              Text(app.name).font(.system(size: 13)).lineLimit(1)
              Spacer()
              Text(ByteText.compact(app.memoryBytes)).font(.system(size: 13))
                .monospacedDigit().foregroundStyle(.secondary)
            }.padding(.vertical, 10)
          }
        }.padding(.top, 4)
      }.padding(24)
    }
  }
}

private struct ResourceCard: View {
  let title: String
  let value: String
  let detail: String
  let samples: [ResourceSample]
  let kind: ResourceKind
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: action) {
        HStack {
          Text(title).font(.system(size: 13, weight: .semibold))
          Spacer()
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).help("Open \(title.lowercased())")
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(value).font(.system(size: 30, weight: .semibold)).monospacedDigit()
        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      ResourcePlot(samples: samples, kind: kind, color: BlitzUI.mint, seconds: 300)
        .frame(height: 90)
        .help("Usage over the last 5 minutes")
    }.frame(maxWidth: .infinity, alignment: .leading).panelCard(padding: 20)
  }
}

struct AppMemoryIcon: View {
  let app: MemoryApp
  var body: some View {
    Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
      .resizable().frame(width: 24, height: 24)
  }
}
