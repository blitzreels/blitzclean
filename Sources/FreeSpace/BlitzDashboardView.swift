import AppKit
import Charts
import SwiftUI

enum CleanPage: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case memory = "Memory"
  case cpu = "CPU"
  case cleanup = "Clean storage"
  case files = "Large files"
  case dependencies = "Dependencies"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .memory: "memorychip"
    case .cpu: "cpu"
    case .cleanup: "sparkles"
    case .files: "doc.on.doc"
    case .dependencies: "shippingbox"
    }
  }
}

@MainActor
final class CleanNavigation: ObservableObject {
  @Published var page = CleanPage.overview
}

struct BlitzDashboardView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var cleanup: QuickCleanModel
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var launchAtLogin: LaunchAtLoginController
  @ObservedObject var developerBrowser: DeveloperBrowserModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var workspaces: WorkspaceController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          BrandMark()
          VStack(alignment: .leading, spacing: 3) {
            Text("BlitzClean").font(.title3.bold())
            Text("by BlitzReels").font(.caption).foregroundStyle(.secondary)
          }
        }.padding(20)
        VStack(spacing: 4) {
          ForEach(CleanPage.allCases) { page in
            Button {
              navigation.page = page
            } label: {
              Label(page.rawValue, systemImage: page.symbol)
                .font(.system(size: 13, weight: navigation.page == page ? .semibold : .medium))
                .foregroundStyle(navigation.page == page ? BlitzUI.mint : BlitzUI.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(
                  navigation.page == page ? BlitzUI.mint.opacity(0.09) : .clear,
                  in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(navigation.page == page ? "Selected" : "")
          }
        }.padding(.horizontal, 12)
        Spacer()
        VStack(alignment: .leading, spacing: 15) {
          Button("Developer tools", systemImage: "terminal") {
            openWindow(id: "workspace")
          }
          SettingsLink { Label("Settings", systemImage: "gearshape") }
          Divider()
          Label("Local. Private. Open source.", systemImage: "lock.shield")
            .font(.caption2).foregroundStyle(.secondary)
          Link("BlitzReels / BlitzClean ↗", destination: AppBrand.repositoryURL)
            .font(.caption2).foregroundStyle(.secondary)
        }.buttonStyle(.plain).padding(20)
      }.background(BlitzUI.sidebarBackground).navigationSplitViewColumnWidth(
        min: 205, ideal: 215, max: 250)
    } detail: {
      Group {
        switch navigation.page {
        case .overview: overview
        case .memory: MemoryControlView(monitor: monitor, model: memory)
        case .cpu: CPUControlView(monitor: monitor)
        case .cleanup: QuickCleanView(model: cleanup, history: storage.overview, monitor: monitor)
        case .files: LargeFileReviewView(model: storage.overview, monitor: monitor)
        case .dependencies:
          DeveloperBrowserView(
            kind: .dependencies, model: developerBrowser,
            processes: processes, workspaces: workspaces, history: storage.overview)
        }
      }
      .navigationTitle(navigation.page.rawValue)
      .toolbar {
        ToolbarItem(placement: .automatic) {
          HStack(spacing: 7) {
            Circle().fill(AppBrand.accent).frame(width: 6, height: 6)
            Text("Live · every 2s").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
    .blitzTheme()
    .frame(minWidth: 940, minHeight: 680)
    .task {
      monitor.refresh()
      memory.refresh()
    }
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          VStack(alignment: .leading, spacing: 7) {
            Text("A little breathing room.").font(.system(size: 30, weight: .semibold))
            Text("Your Mac, at a glance. Take back memory and storage.")
              .font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
          Label(monitor.snapshot.healthStatus.title, systemImage: "circle.fill")
            .font(.caption.weight(.medium)).foregroundStyle(memory.risk.tone.color)
            .padding(10).background(memory.risk.tone.color.opacity(0.09), in: Capsule())
        }
        HStack(spacing: 14) {
          ResourceCard(
            title: "Memory", value: ByteText.compact(monitor.snapshot.ramUsed),
            subtitle: "of \(ByteText.compact(monitor.snapshot.ramTotal)) used",
            symbol: "memorychip",
            color: AppBrand.accent, samples: monitor.resourceSamples, kind: .memory)
          ResourceCard(
            title: "CPU", value: monitor.snapshot.cpuUsage.map(PercentText.make) ?? "Sampling…",
            subtitle:
              "\(ProcessInfo.processInfo.activeProcessorCount) cores · \(monitor.snapshot.thermalStatus.title.lowercased())",
            symbol: "cpu", color: BlitzUI.mint, samples: monitor.resourceSamples, kind: .cpu)
        }
        HStack(alignment: .top, spacing: 14) {
          VStack(alignment: .leading, spacing: 16) {
            Label("Memory you can manage", systemImage: "memorychip").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(ByteText.full(monitor.snapshot.ramAvailable)).font(
                .system(size: 27, weight: .semibold)
              ).monospacedDigit()
              Text("available").foregroundStyle(.secondary)
            }
            Text(
              "Pressure: \(memory.pressure.title.lowercased()) · Swap: \(memory.sample?.swapUsed.map(ByteText.compact) ?? "checking")"
            )
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(memory.apps.prefix(3)) { app in
              HStack(spacing: 8) {
                AppMemoryIcon(app: app)
                Text(app.name).lineLimit(1)
                Spacer()
                Text(ByteText.compact(app.memoryBytes)).monospacedDigit().foregroundStyle(
                  .secondary)
              }.font(.callout)
            }
            Button {
              navigation.page = .memory
            } label: {
              Label("Free RAM…", systemImage: "memorychip").frame(maxWidth: .infinity)
            }.buttonStyle(BlitzButtonStyle(.accent)).controlSize(.large)
            Text("Choose apps to quit. Unsaved work stays protected by normal save dialogs.")
              .font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).panelCard(padding: 20)
          VStack(alignment: .leading, spacing: 16) {
            Label("Storage on this Mac", systemImage: "internaldrive").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(ByteText.full(monitor.snapshot.diskAvailable)).font(
                .system(size: 27, weight: .semibold)
              ).monospacedDigit()
              Text("free").foregroundStyle(.secondary)
            }
            CapacityBar(
              usedRatio: 1 - Double(monitor.snapshot.diskAvailable)
                / Double(max(1, monitor.snapshot.diskTotal)),
              tone: MenuBarTones.disk(monitor.snapshot))
            Text("\(ByteText.full(monitor.snapshot.diskTotal)) total · internal drive")
              .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(
              cleanup.scannedAt == nil
                ? "Find the files you can remove."
                : "\(ByteText.full(cleanup.totalBytes)) in older rebuildable caches"
            )
            .font(.callout.weight(.medium))
            Text(
              "Review download caches and build leftovers. See why each item can go and what comes back."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button {
              navigation.page = .cleanup
              if cleanup.scannedAt == nil { cleanup.scan() }
            } label: {
              Label("Find cleanup opportunities", systemImage: "sparkles").frame(
                maxWidth: .infinity)
            }.buttonStyle(BlitzButtonStyle(.accent)).controlSize(.large)
            Button("Browse large files") { navigation.page = .files }.buttonStyle(.link)
          }.frame(maxWidth: .infinity, alignment: .leading).panelCard(padding: 20)
        }
        HStack(spacing: 12) {
          Image(systemName: "shield.lefthalf.filled").font(.title2).foregroundStyle(AppBrand.accent)
          VStack(alignment: .leading, spacing: 4) {
            Text("You choose what goes.").font(.callout.weight(.semibold))
            Text(
              "No automatic app closing or file deletion. External drives stay out of quick cleanup."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }.padding(.horizontal, 4)
      }.padding(28)
    }
  }
}

enum ResourceKind { case memory, cpu }

struct ResourcePlot: View {
  let samples: [ResourceSample]
  let kind: ResourceKind
  let color: Color
  let seconds: TimeInterval

  private var visibleSamples: [ResourceSample] {
    let end = samples.last?.date ?? .now
    return samples.filter { $0.date >= end.addingTimeInterval(-seconds) }
  }

  var body: some View {
    Chart(visibleSamples) { sample in
      if let value = kind == .cpu ? sample.cpu : sample.memory {
        AreaMark(x: .value("Time", sample.date), y: .value("Usage", value))
          .foregroundStyle(
            LinearGradient(
              colors: [color.opacity(0.25), color.opacity(0.015)], startPoint: .top,
              endPoint: .bottom))
        LineMark(x: .value("Time", sample.date), y: .value("Usage", value))
          .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
      }
    }
    .chartYScale(domain: 0...1)
    .chartXScale(
      domain: (samples.last?.date ?? .now).addingTimeInterval(
        -seconds)...(samples.last?.date ?? .now)
    )
    .chartXAxis(.hidden).chartYAxis(.hidden)
    .accessibilityLabel(kind == .cpu ? "CPU usage history" : "RAM usage history")
  }
}

struct ResourceCard: View {
  let title: String
  let value: String
  let subtitle: String
  let symbol: String
  let color: Color
  let samples: [ResourceSample]
  let kind: ResourceKind

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: symbol).font(.callout.weight(.medium)).foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(value).font(.system(size: 32, weight: .semibold)).monospacedDigit()
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      ResourcePlot(samples: samples, kind: kind, color: color, seconds: 300).frame(height: 70)
      HStack {
        Text("5 minutes ago")
        Spacer()
        Text("Now")
      }.font(.caption2).foregroundStyle(.tertiary)
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

struct CPUControlView: View {
  @ObservedObject var monitor: SystemMonitor
  @State private var seconds = 300.0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text("Know what’s working hard.").font(.title.bold())
            Text(
              "\(ProcessInfo.processInfo.activeProcessorCount) CPU cores · \(monitor.snapshot.thermalStatus.title) thermals"
            )
            .foregroundStyle(.secondary)
          }
          Spacer()
          Text(monitor.snapshot.cpuUsage.map(PercentText.make) ?? "—")
            .font(.system(size: 40, weight: .semibold)).monospacedDigit()
        }
        VStack(spacing: 14) {
          HStack {
            Text("Total CPU usage").font(.headline)
            Spacer()
            HistoryRangePicker(seconds: $seconds)
          }
          ResourcePlot(
            samples: monitor.resourceSamples, kind: .cpu, color: BlitzUI.mint, seconds: seconds
          )
          .frame(height: 150)
          HStack {
            Text("\(Int(seconds / 60)) minutes ago")
            Spacer()
            Text("Now · 0–100% of all cores")
          }
          .font(.caption).foregroundStyle(.secondary)
        }.panelCard(padding: 20)
        HStack {
          Text("Top readable CPU processes").font(.headline)
          Spacer()
          Button("Activity Monitor") {
            NSWorkspace.shared.open(
              URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
          }
        }
        Text(
          "Live readings for processes macOS allows us to inspect. A process at 100% uses one core; multicore work can exceed 100%."
        )
        .font(.caption).foregroundStyle(.secondary)
        if monitor.topCPUProcesses.isEmpty {
          ContentUnavailableView(
            "Sampling CPU activity", systemImage: "cpu",
            description: Text(
              "Two readings are needed to measure a process. Keep this window open for a few seconds."
            ))
        }
        LazyVStack(spacing: 0) {
          ForEach(monitor.topCPUProcesses) { process in
            HStack(spacing: 12) {
              Image(systemName: "waveform.path").foregroundStyle(BlitzUI.mint).frame(width: 24)
              VStack(alignment: .leading, spacing: 4) {
                Text(process.name).font(.callout.weight(.medium)).lineLimit(1)
                Text("PID \(process.id)").font(.caption2).foregroundStyle(.secondary)
              }
              Spacer()
              Text(String(format: "%.1f%%", process.percent)).monospacedDigit().font(
                .callout.weight(.semibold))
            }.padding(14)
            Divider()
          }
        }.panelCard(padding: 0)
      }.padding(28)
    }
  }
}

struct HistoryRangePicker: View {
  @Binding var seconds: Double
  var body: some View {
    Picker("History", selection: $seconds) {
      Text("1m").tag(60.0)
      Text("5m").tag(300.0)
      Text("15m").tag(900.0)
    }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
  }
}
