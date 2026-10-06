import AppKit
import SwiftUI

struct RemovedBeforeView: View {
  @ObservedObject var model: RepeatCleanupModel
  @Binding var pending: [RemovedEntry]
  @State private var showsAll = false

  private static let rowLimit = 8

  private func detail(_ summary: RepeatCleanupModel.Summary) -> String {
    if model.entries.isEmpty { return "Folders you remove appear here when they grow back" }
    if model.isChecking && model.statuses.isEmpty { return "Checking what grew back…" }
    return summary.regrown.isEmpty
      ? "\(model.entries.count) folders · none grew back"
      : "\(summary.regrown.count) grew back"
  }

  var body: some View {
    let summary = model.summary
    let rows = showsAll ? summary.ordered : Array(summary.ordered.prefix(Self.rowLimit))
    BlitzStorageSection(
      title: "Removed before", symbol: "arrow.counterclockwise", detail: detail(summary),
      trailing: summary.regrown.isEmpty ? nil : ByteText.full(summary.regrownBytes),
      showsContent: true
    ) {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Text(model.message ?? "Build output, dependencies, and caches rebuild on their own.")
            .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText).lineLimit(2)
            .textSelection(.enabled)
          Spacer()
          if model.isChecking { ProgressView().controlSize(.small) }
          if summary.ready.count > 1 {
            Button("Remove \(summary.ready.count) again…") { pending = summary.ready }
              .blitzButton(.accent).controlSize(.small).disabled(!model.removing.isEmpty)
          }
        }.padding(.horizontal, 16).padding(.vertical, 12)
        ForEach(rows) { entry in
          BlitzRowDivider(leading: 16)
          row(entry)
        }
        if summary.ordered.count > Self.rowLimit {
          BlitzRowDivider(leading: 16)
          BlitzShowAllButton(total: summary.ordered.count, noun: "folders", isExpanded: $showsAll)
            .padding(.vertical, 8)
        }
      }
    }
    .task { model.check() }
  }

  private func row(_ entry: RemovedEntry) -> some View {
    let status = model.statuses[entry.id]
    let back = model.isBack(entry)
    let removing = model.removing.contains(entry.id)
    let problem = model.failures[entry.id] ?? (back ? status?.blocker : nil)
    return HStack(spacing: 12) {
      Image(systemName: symbol(entry.target.recipe)).font(.system(size: 14))
        .foregroundStyle(BlitzUI.secondaryText).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.target.title).font(BlitzType.rowTitle).lineLimit(1)
        Text(location(entry)).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle).help(entry.target.path)
        Text(problem ?? history(entry)).font(BlitzType.caption)
          .foregroundStyle(problem == nil ? BlitzUI.tertiaryText : BlitzUI.warning).lineLimit(2)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Group {
        if let bytes = status?.bytes, back {
          BlitzTrailingValue(value: ByteText.full(bytes), detail: nil)
        } else if status == nil && model.isChecking {
          Text("Checking…").font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
        } else {
          BlitzStatusBadge(title: "Not back", tone: .muted)
        }
      }.frame(width: 96, alignment: .trailing)
      Group {
        if removing {
          ProgressView().controlSize(.small)
        } else if back {
          Button(entry.target.recipe == .pnpmPrune ? "Prune…" : "Remove again…") {
            pending = [entry]
          }.blitzButton(.secondary).controlSize(.small).disabled(status?.blocker != nil)
        }
      }.frame(width: 124, alignment: .trailing)
      BlitzActionMenu(label: "More actions for \(entry.target.title)") {
        Button("Show in Finder") { reveal(entry.target.path) }
        Button("Copy path") {
          Pasteboard.copy(entry.target.path)
        }
      }
    }.padding(.horizontal, 16).padding(.vertical, 10)
  }

  private func location(_ entry: RemovedEntry) -> String {
    let home = NSHomeDirectory()
    let path = entry.target.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  private func history(_ entry: RemovedEntry) -> String {
    let times = entry.removals == 1 ? "Removed once" : "Removed \(entry.removals)×"
    let last = entry.lastRemovedAt.formatted(.dateTime.month(.abbreviated).day())
    let freed = entry.freedBytes > 0 ? " · \(ByteText.full(entry.freedBytes)) freed" : ""
    return "\(times) · last \(last)\(freed)"
  }

  private func symbol(_ recipe: RegrowRecipe) -> String {
    switch recipe {
    case .folder: "hammer"
    case .dependencies: "shippingbox"
    case .pnpmPrune: "archivebox"
    }
  }

  private func reveal(_ path: String) {
    Finder.reveal(
      FileManager.default.fileExists(atPath: path)
        ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path)
  }
}

extension [RemovedEntry] {
  @MainActor func confirmation(_ model: RepeatCleanupModel) -> (title: String, message: String) {
    let bytes = reduce(0) { $0 + (model.statuses[$1.id]?.bytes ?? 0) }
    let dependencies = contains { $0.target.recipe == .dependencies }
    let prune = contains { $0.target.recipe == .pnpmPrune }
    let title =
      count == 1
      ? (first?.target.recipe == .pnpmPrune
        ? "Prune the pnpm store?" : "Remove \(first?.target.title ?? "folder") again?")
      : "Remove \(count) folders again?"
    var notes = [
      "About \(ByteText.full(bytes)). Each folder is checked again for running builds first."
    ]
    if count <= 4 { notes.insert(map(\.target.path).joined(separator: "\n"), at: 0) }
    if dependencies { notes.append("Dependencies need a reinstall before the next run.") }
    if prune { notes.append("pnpm store prune keeps packages your projects still use.") }
    return (title, notes.joined(separator: "\n\n"))
  }
}

struct RemovalLogView: View {
  @ObservedObject var history: CleanupOverviewModel
  @State private var showsAll = false

  private static let rowLimit = 12

  var body: some View {
    let wins = history.ledger.wins
    let rows = showsAll ? wins : Array(wins.prefix(Self.rowLimit))
    BlitzStorageSection(
      title: "Removal log", symbol: "list.bullet.rectangle",
      detail: wins.isEmpty ? "Nothing removed yet" : "\(wins.count) removals measured on this Mac",
      trailing: wins.isEmpty ? nil : ByteText.full(history.ledger.internalGains),
      showsContent: true
    ) {
      VStack(spacing: 0) {
        ForEach(rows) { win in
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(win.title).font(BlitzType.rowTitle).lineLimit(1)
              Text(win.paths.count == 1 ? win.paths[0] : "\(win.paths.count) items")
                .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
                .lineLimit(1).truncationMode(.middle).help(win.paths.joined(separator: "\n"))
                .textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            BlitzTrailingValue(
              value: (win.bytes ?? win.measuredGain).map(ByteText.full) ?? "—",
              detail: win.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            ).frame(width: 120, alignment: .trailing)
          }.padding(.horizontal, 16).padding(.vertical, 9)
          if win.id != rows.last?.id { BlitzRowDivider(leading: 16) }
        }
        if wins.count > Self.rowLimit {
          BlitzRowDivider(leading: 16)
          BlitzShowAllButton(total: wins.count, noun: "removals", isExpanded: $showsAll)
            .padding(.vertical, 8)
        }
        if let error = history.historyError {
          BlitzStatusLine(text: error, tone: .warning).padding(12)
        }
      }
    }
  }
}
