import SwiftUI

/// Builds the brake paused, each with Resume and Stop. Pausing keeps a build's memory, so once memory
/// stays short for two minutes Stop becomes the main action: it is the only one that frees the memory.
struct PausedBuildsSection: View {
  @ObservedObject var processes: DevProcessModel

  var body: some View {
    let entries = processes.brakePaused.sorted { $0.process.footprint > $1.process.footprint }
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        BlitzSectionHeader(title: "Paused to protect memory", count: entries.count) {
          Text("Paused builds keep their memory").font(BlitzType.caption)
            .foregroundStyle(BlitzUI.tertiaryText)
        }
        VStack(spacing: 0) {
          ForEach(entries, id: \.process.identity.process.processID) { entry in
            row(entry)
            if entry != entries.last { BlitzRowDivider(leading: 56) }
          }
        }.blitzTable()
      }
    }
  }

  private func isStuck(_ entry: BuildBrakeEntry) -> Bool {
    Date.now.timeIntervalSince(entry.pausedAt) >= BuildBrakePolicy.stuckAfter
      && processes.pressure.risk >= .warning
  }

  private func row(_ entry: BuildBrakeEntry) -> some View {
    let stuck = isStuck(entry)
    let minutes = max(1, Int(Date.now.timeIntervalSince(entry.pausedAt) / 60))
    return HStack(spacing: 12) {
      BlitzIconTile(symbol: "pause.circle", tone: stuck ? .warning : .muted, size: 28)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(entry.process.label).font(BlitzType.rowTitle).lineLimit(1)
          BlitzStatusBadge(title: "Paused", tone: .warning)
        }
        Text(
          stuck
            ? "Paused \(minutes) min · memory is still short, so it can't resume. Stop frees its memory."
            : "Paused \(minutes) min · resumes on its own when memory recovers"
        ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
      BlitzTrailingValue(value: ByteText.compact(entry.process.footprint), detail: nil)
        .frame(width: 80, alignment: .trailing)
      Button {
        processes.releaseBrake(.init(entry: entry, stop: stuck))
      } label: {
        BlitzActionLabel(title: stuck ? "Stop" : "Resume")
      }.blitzButton(.secondary).controlSize(.small).frame(width: 96, alignment: .trailing)
      BlitzActionMenu(label: "More actions for \(entry.process.label)") {
        Button(stuck ? "Resume" : "Stop") {
          processes.releaseBrake(.init(entry: entry, stop: !stuck))
        }
      }
    }.blitzRow()
  }
}
