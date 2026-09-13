import AppKit
import SwiftUI

struct DevProcessView: View {
  @ObservedObject var model: DevProcessModel
  @State private var confirmation: ProcessStopConfirmation?
  @State var section = ProcessPageSection.cpu

  private var grouped: [(group: DevProcessGroup, processes: [DevProcess])] {
    DevProcessGroup.allCases.compactMap { group in
      let processes = model.processes.filter { process in
        process.kind.group == group
      }
      guard !processes.isEmpty else {
        return nil
      }

      return (group, processes)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      if let statusMessage = model.statusMessage {
        StatusLine(message: statusMessage)
          .padding(.horizontal, 18)
          .padding(.top, 12)
      }

      Picker("View", selection: $section) {
        ForEach(ProcessPageSection.allCases) { section in
          Text(section.rawValue).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 18)
      .padding(.vertical, 12)

      if section == .cpu {
        CPUProcessList(processes: model.cpuProcesses, isRefreshing: model.isRefreshing)
      } else if model.processes.isEmpty && model.isRefreshing {
        ProgressView("Scanning processes and ports…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.processes.isEmpty {
        ContentUnavailableView(
          "Nothing running",
          systemImage: "terminal",
          description: Text("No AI agents, dev servers, or listening ports found for your user.")
        )
      } else if section == .projects {
        projects
      } else {
        list
      }
    }
    .frame(minWidth: 700, minHeight: 500)
    .task {
      model.refresh()
    }
    .alert(item: $confirmation) { candidate in
      Alert(
        title: Text(candidate.title),
        message: Text(candidate.message),
        primaryButton: .destructive(Text(candidate.force ? "Force Quit" : "Stop Servers")) {
          if candidate.force, let request = candidate.requests.first {
            model.stop(request)
          } else {
            model.stopProject(candidate.requests)
          }
        },
        secondaryButton: .cancel()
      )
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "terminal.fill")
        .font(.title2)
        .foregroundStyle(Color.accentColor)
        .frame(width: 42, height: 42)
        .background(
          Color.accentColor.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 11, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text("Processes")
          .font(.title2.weight(.semibold))
        Text(summaryText)
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Text("Live background processes can keep running after their browser or editor closes.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if let scannedAt = model.scannedAt {
        Text("Updated \(scannedAt, style: .relative) ago")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button {
        model.refresh()
      } label: {
        if model.isRefreshing {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise")
        }
      }
      .disabled(model.isRefreshing)
      .help("Refresh")
    }
    .padding(18)
  }

  private var summaryText: String {
    let summary = model.summary
    var parts: [String] = []
    if summary.claudeCount > 0 {
      parts.append("\(summary.claudeCount) Claude Code")
    }

    if summary.codexCount > 0 {
      parts.append("\(summary.codexCount) Codex")
    }

    if summary.agentCount > 0 {
      parts.append("\(summary.agentCount) other agents")
    }

    parts.append("\(summary.serverCount) servers")
    parts.append("\(summary.ports.count) open ports")
    return parts.joined(separator: " · ")
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        ForEach(grouped, id: \.group) { entry in
          Section {
            ForEach(entry.processes) { process in
              DevProcessRow(
                process: process,
                icon: ProcessIconResolver.icon(for: process, probes: model.probes),
                probes: model.probes,
                isStopping: model.stoppingIDs.contains(process.processID),
                onOpenPort: { port in
                  model.openPort(port)
                },
                onStop: { selected in
                  model.stop(model.stopRequest(selected))
                },
                onForce: requestForce
              )
              .padding(.horizontal, 18)
              .padding(.vertical, 6)
              Divider()
                .padding(.leading, 58)
            }
          } header: {
            HStack {
              Text(entry.group.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Spacer()
              Text(
                ByteText.full(
                  entry.processes.reduce(0) { result, process in result + process.memoryBytes })
              )
              .font(.caption)
              .foregroundStyle(.tertiary)
              .monospacedDigit()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(.bar)
          }
        }
      }
      .padding(.bottom, 12)
    }
  }

  private func requestForce(_ process: DevProcess) {
    let request = model.stopRequest(process)
    confirmation = ProcessStopConfirmation(
      id: "force-\(process.processID)", title: "Force quit \(process.name)?",
      message: "This ends the process immediately. Unsaved work in it is lost.",
      requests: [DevStopRequest(process: process, expected: request.expected, force: true)],
      force: true)
  }

  private var projects: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        Text(
          "Stop servers for the project you’re finished with. AI agents stay separate in All Processes."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        ForEach(DevProject.grouped(model.processes)) { project in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.headline)
                Text(project.directory)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .help(project.directory)
              }
              Spacer()
              if !project.servers.isEmpty {
                Button("Stop Servers (\(project.servers.count))") {
                  let requests = project.servers.map { model.stopRequest($0) }
                  confirmation = ProcessStopConfirmation(
                    id: project.id, title: "Stop \(project.name) servers?",
                    message: requests.map {
                      "\($0.process.name) · \($0.process.listeningPorts.map { ":\($0)" }.joined(separator: ", "))"
                    }.joined(separator: "\n")
                      + "\n\nLocal pages and connected tools using these servers will be unavailable until restarted. Claude and ChatGPT stay running.",
                    requests: requests, force: false)
                }
                .disabled(project.servers.contains { model.stoppingIDs.contains($0.processID) })
              }
            }
            ForEach(project.processes) { process in
              DevProcessRow(
                process: process,
                icon: ProcessIconResolver.icon(for: process, probes: model.probes),
                probes: model.probes,
                isStopping: model.stoppingIDs.contains(process.processID),
                onOpenPort: { model.openPort($0) },
                onStop: { model.stop(model.stopRequest($0)) },
                onForce: requestForce)
              Divider()
            }
          }
        }
        if DevProject.grouped(model.processes).isEmpty {
          Text("No project servers found. Other processes are listed in All Processes.")
            .foregroundStyle(.secondary)
        }
      }
      .padding(18)
    }
  }

}

private struct DevProcessRow: View {
  let process: DevProcess
  let icon: NSImage?
  let probes: [Int: PortProbe]
  let isStopping: Bool
  let onOpenPort: (Int) -> Void
  let onStop: (DevProcess) -> Void
  let onForce: (DevProcess) -> Void

  var body: some View {
    HStack(spacing: 12) {
      if process.kind == .devServer {
        ProjectIcon(
          directory: process.workingDirectory, processName: process.name, size: 28,
          fallbackSymbol: process.kind.systemImage)
      } else if let icon {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
          .frame(width: 28, height: 28)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      } else {
        ProjectIcon(
          directory: process.workingDirectory, processName: process.name, size: 28,
          fallbackSymbol: process.kind.systemImage)
      }

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(process.name)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          if let projectName = process.projectName {
            Text(projectName)
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
              .help(process.workingDirectory ?? "")
          }
        }

        if let probeLabel {
          Text(probeLabel)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }

        HStack(spacing: 6) {
          Text("PID \(process.processID)")
          if let terminal = process.terminal {
            Text("· \(terminal)")
          }
          Text("· up \(process.elapsed)")
          if !process.detail.isEmpty {
            Text("· \(process.detail)")
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
      }

      Spacer(minLength: 8)

      if !process.listeningPorts.isEmpty {
        HStack(spacing: 4) {
          ForEach(process.listeningPorts.prefix(3), id: \.self) { port in
            Button {
              onOpenPort(port)
            } label: {
              HStack(spacing: 4) {
                if let favicon = ProcessIconResolver.favicon(probes[port]) {
                  Image(nsImage: favicon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                } else {
                  Image(systemName: probes[port]?.kind == .api ? "curlybraces" : "globe")
                    .font(.caption2)
                }
                Text(":" + String(port))
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(portHelp(port))
          }
          if process.listeningPorts.count > 3 {
            Text("+\(process.listeningPorts.count - 3)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      VStack(alignment: .trailing, spacing: 2) {
        Text(ByteText.full(process.memoryBytes))
          .font(.callout.weight(.semibold))
        Text("\(process.cpuPercent.formatted(.number.precision(.fractionLength(0))))% CPU")
          .font(.caption)
          .foregroundStyle(process.cpuPercent >= 50 ? Color.orange : Color.secondary)
      }
      .monospacedDigit()
      .frame(width: 84, alignment: .trailing)

      Menu {
        Button("Stop (SIGTERM)") {
          onStop(process)
        }
        Button("Force Quit (SIGKILL)", role: .destructive) {
          onForce(process)
        }
        if let workingDirectory = process.workingDirectory {
          Divider()
          Button("Reveal Project in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workingDirectory)])
          }
        }
      } label: {
        Text(isStopping ? "Stopping…" : "Stop")
      } primaryAction: {
        onStop(process)
      }
      .controlSize(.small)
      .disabled(isStopping)
      .fixedSize()
    }
  }

  private var probeLabel: String? {
    let labels = process.listeningPorts.compactMap { port -> String? in
      guard let probe = probes[port], let label = probe.label else {
        return nil
      }

      return process.listeningPorts.count > 1 ? ":\(port) \(label)" : label
    }
    return labels.isEmpty ? nil : labels.joined(separator: " · ")
  }

  private func portHelp(_ port: Int) -> String {
    guard let probe = probes[port] else {
      return "Open http://localhost:\(port)"
    }

    return [probe.label, probe.kind.title, "http://localhost:\(port)"].compactMap { $0 }.joined(
      separator: " · ")
  }

  private var kindColor: Color {
    switch process.kind {
    case .claudeCode:
      .orange
    case .codex:
      .primary
    case .aiAgent:
      .purple
    case .devServer:
      .green
    case .listener:
      .blue
    case .simulator:
      .teal
    case .shell:
      .secondary
    }
  }
}

struct StatusLine: View {
  let message: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "info.circle.fill")
      Text(message)
      Spacer()
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }
}

enum ProcessPageSection: String, CaseIterable, Identifiable {
  case cpu = "CPU"
  case projects = "Projects"
  case all = "All Processes"
  var id: Self { self }
}

private struct ProcessStopConfirmation: Identifiable {
  let id: String
  let title: String
  let message: String
  let requests: [DevStopRequest]
  let force: Bool
}

private struct CPUProcessList: View {
  let processes: [CPUProcess]
  let isRefreshing: Bool

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Highest CPU first · 100% = one CPU core")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Activity Monitor") {
            NSWorkspace.shared.open(
              URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
          }
          .controlSize(.small)
        }
        .padding(.bottom, 12)
        if processes.isEmpty {
          Text(isRefreshing ? "Checking CPU usage…" : "No CPU activity in this sample.")
            .foregroundStyle(.secondary)
        }
        ForEach(processes.prefix(30)) { process in
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text(process.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
              HStack(spacing: 6) {
                if let directory = process.workingDirectory {
                  Text(URL(fileURLWithPath: directory).lastPathComponent)
                    .lineLimit(1)
                    .help(directory)
                }
                Text("PID \(process.processID)")
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(process.cpuPercent.formatted(.number.precision(.fractionLength(1))))%")
              .font(.body.weight(.semibold))
              .monospacedDigit()
              .foregroundStyle(process.cpuPercent >= 50 ? Color.orange : Color.primary)
          }
          .padding(.vertical, 10)
          Divider()
        }
      }
      .padding(18)
    }
  }
}
