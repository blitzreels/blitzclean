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
              .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
            Spacer()
            HistoryRangePicker(seconds: $seconds)
          }
          ResourcePlot(
            samples: monitor.resourceSamples, kind: .cpu, color: BlitzUI.mint, seconds: seconds
          )
          .frame(height: 130)
          .help("Total CPU usage across all cores, from 0 to 100%")
          if monitor.snapshot.thermalStatus != .nominal {
            BlitzStatusBadge(
              title: "Thermals: \(monitor.snapshot.thermalStatus.title)", tone: .warning)
          }
        }.panelCard(padding: 20)
        let processes = monitor.topCPUProcesses
        BlitzSectionHeader(title: "Processes", count: nil) {
          Button("Open Activity Monitor") {
            NSWorkspace.shared.open(
              URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
          }.blitzButton(.quiet).controlSize(.small)
        }
        LazyVStack(spacing: 0) {
          if processes.isEmpty {
            BlitzEmptyRow(text: "Measuring CPU activity…", isLoading: true)
          }
          ForEach(processes) { process in
            HStack(spacing: 12) {
              ApplicationIcon(source: .process(process.id), size: 28, fallback: "terminal")
              Text(process.name).font(BlitzType.rowTitle).lineLimit(1)
              Spacer()
              BlitzTrailingValue(
                value: process.percent.formatted(.number.precision(.fractionLength(1))) + "%",
                detail: nil)
            }.blitzRow()
              .help("PID \(process.id)")
            if process.id != processes.last?.id { BlitzRowDivider(leading: 56) }
          }
        }.blitzTable()
        Text("100% per process equals one core. macOS restricts access to some processes.")
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }.padding(BlitzUI.pagePadding)
    }
  }
}
