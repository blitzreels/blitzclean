import AppKit
import SwiftUI

struct CPUControlView: View {
  @ObservedObject var monitor: SystemMonitor
  @AppStorage("history.cpuSeconds") private var seconds = 86_400.0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 18) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(monitor.snapshot.cpuUsage.map(PercentText.make) ?? "—")
              .font(BlitzUI.valueFont).monospacedDigit()
            Text("\(ProcessInfo.processInfo.activeProcessorCount) cores")
              .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            HistoryRangePicker(seconds: $seconds)
          }
          ResourcePlot(
            samples: monitor.resourceSamples, kind: .cpu, color: BlitzUI.mint, seconds: seconds
          )
          .frame(height: 130)
          .help("Total CPU usage across all cores, from 0 to 100%")
          if monitor.snapshot.thermalStatus != .nominal {
            Text("Thermals: \(monitor.snapshot.thermalStatus.title)")
              .font(.system(size: 12)).foregroundStyle(.orange)
          }
        }.panelCard(padding: 20)
        HStack {
          Text("Processes").font(.system(size: 13, weight: .semibold))
          Spacer()
          Button("Activity Monitor") {
            NSWorkspace.shared.open(
              URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
          }.buttonStyle(BlitzButtonStyle(.quiet))
        }
        if monitor.topCPUProcesses.isEmpty {
          ContentUnavailableView("Measuring CPU activity…", systemImage: "cpu")
            .frame(maxWidth: .infinity)
        }
        LazyVStack(spacing: 0) {
          ForEach(monitor.topCPUProcesses) { process in
            HStack(spacing: 12) {
              ApplicationIcon(source: .process(process.id), size: 28, fallback: "terminal")
              Text(process.name).font(.system(size: 13)).lineLimit(1)
              Spacer()
              Text(String(format: "%.1f%%", process.percent))
                .font(.system(size: 13, weight: .medium)).monospacedDigit()
            }.blitzRow()
              .help("PID \(process.id)")
            if process.id != monitor.topCPUProcesses.last?.id { BlitzRowDivider(leading: 56) }
          }
        }.blitzTable()
        Text("100% per process equals one core. macOS restricts access to some processes.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(BlitzUI.pagePadding)
    }
  }
}
