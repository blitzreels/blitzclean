import AppKit
import SwiftUI

struct CleanupWinsView: View {
  @ObservedObject var overview: CleanupOverviewModel
  let available: UInt64
  let total: UInt64
  private let target = DiskSpacePolicy.reserveBytes

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Your cleanup wins").font(.headline)
        Spacer()
        Text("Mac storage").font(.caption).foregroundStyle(.secondary)
      }
      HStack(alignment: .top, spacing: 24) {
        metric(
          CleanupMetric(
            title: "Measured gains", value: ByteText.full(overview.ledger.internalGains),
            color: .green))
        Divider()
        metric(
          CleanupMetric(
            title: "Free now", value: ByteText.full(available),
            color: MetricTone.forDisk(DiskCapacityInput(available: available, total: total)).color))
        Divider()
        metric(
          CleanupMetric(
            title: "To \(DiskSpacePolicy.reserveLabel) reserve",
            value: available >= target ? "Reached" : ByteText.full(target - available),
            color: .primary))
      }
      .fixedSize(horizontal: false, vertical: true)
      if let last = overview.ledger.latestInternal, let after = last.after {
        HStack(spacing: 6) {
          Image(systemName: after.available > available ? "arrow.down.right" : "checkmark.circle")
          if after.available > available {
            Text("\(ByteText.full(after.available - available)) used since the last cleanup")
          } else {
            Text("Free space is at or above the last cleanup result")
          }
          Spacer()
          Text(last.date, style: .relative).foregroundStyle(.secondary)
        }
        .font(.callout)
      }
      Text(
        "Gains are changes in disk free space, not added-up folder sizes. Other disk activity affects the measurement."
      )
      .font(.caption).foregroundStyle(.secondary)
      if overview.ledger.wins.isEmpty {
        Text("Your next cleanup will appear here with its measured result.")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        DisclosureGroup("Recent cleanups · \(overview.ledger.wins.count)") {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(overview.ledger.wins.prefix(12)) { win in
              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text(win.title).lineLimit(1)
                  Spacer()
                  Text(win.measuredGain.map { "+\(ByteText.full($0))" } ?? "Unmeasured")
                    .monospacedDigit().foregroundStyle(.green)
                  Text(win.date, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.secondary)
                }
                DisclosureGroup(
                  "\(win.paths.count) item(s) · \(win.after?.isInternal == true ? "Mac" : "Other volume")"
                ) {
                  ForEach(win.paths, id: \.self) { path in
                    Text(path).textSelection(.enabled).frame(
                      maxWidth: .infinity, alignment: .leading)
                  }
                }
                .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .font(.callout).padding(.top, 8)
        }
        .font(.callout)
      }
      if let error = overview.historyError {
        Text(error).font(.caption).foregroundStyle(.orange)
      }
    }
    .padding(18)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
  }

  private func metric(_ input: CleanupMetric) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(input.title).font(.caption).foregroundStyle(.secondary)
      Text(input.value).font(.system(size: 27, weight: .semibold, design: .rounded))
        .monospacedDigit().foregroundStyle(input.color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CleanupMetric {
  let title: String
  let value: String
  let color: Color
}

struct CleanupOpportunitiesView: View {
  @ObservedObject var model: StorageBreakdownModel
  @ObservedObject var overview: CleanupOverviewModel
  @State private var pendingFile: ReviewFile?
  @State private var showsAllFiles = false

  private var quickWins: [StorageItem] {
    guard let active = overview.activeWorkingDirectories else { return [] }
    return Array(
      model.readyItems.filter {
        let path = $0.projectRootPath ?? $0.path
        let root = ReviewFile.canonicalPath(path) ?? path
        let inUse = active.contains { $0 == root || $0.hasPrefix(root + "/") }
        return !inUse && $0.bytes >= 512 * 1_024 * 1_024 && $0.cleanupKind != .simulatorCache
          && CleanupVolume.read($0.path)?.isInternal == true
      }.sorted { $0.bytes > $1.bytes }.prefix(3))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Files worth reviewing").font(.title3.weight(.semibold))
          Text("Largest first · Mac only · files above 256 MiB")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if overview.isScanning {
          ProgressView().controlSize(.small)
          Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
        }
        Button("Refresh files") { overview.refresh() }
          .disabled(overview.isScanning)
      }
      if overview.files.isEmpty {
        Text(
          overview.isScanning
            ? "Looking for large downloads, videos, and temporary files…"
            : "No large files found in the reviewed locations."
        )
        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
      }
      if let message = overview.message {
        Label(
          message,
          systemImage: overview.deletionFailure == nil
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(overview.deletionFailure == nil ? .green : .orange)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let deletingPath = overview.deletingPath {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          VStack(alignment: .leading, spacing: 3) {
            Text("Deleting \(URL(fileURLWithPath: deletingPath).lastPathComponent)…")
              .lineLimit(1).truncationMode(.middle)
            Text(
              overview.queuedFiles.isEmpty
                ? "You can keep browsing and queue more files."
                : "\(overview.queuedFiles.count) queued · you can keep browsing."
            )
            .foregroundStyle(.secondary)
          }
          .font(.callout)
          Spacer(minLength: 0)
        }
      }
      ForEach(showsAllFiles ? overview.files : Array(overview.files.prefix(4))) { file in
        fileRow(file)
        Divider()
      }
      if overview.files.count > 4 {
        Button(showsAllFiles ? "Show fewer files" : "Show all \(overview.files.count) files") {
          showsAllFiles.toggle()
        }.buttonStyle(.link)
      }
      Text(
        "Downloads, Movies, Desktop, and temporary folders · up to 4 levels deep\(overview.scanLimited ? " · partial scan: some locations could not be fully read" : "")"
      )
      .font(.caption).foregroundStyle(.secondary)
      if let scannedAt = overview.scannedAt {
        Text(
          "Checked \(scannedAt.formatted(date: .omitted, time: .shortened)) · removed files update automatically"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if !quickWins.isEmpty {
        Divider().padding(.vertical, 4)
        Text("Rebuildable folders").font(.headline)
        Text(
          "Source stays. Dependencies need reinstalling. Activity is checked again before deletion."
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(quickWins) { item in
          HStack(spacing: 14) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
              Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
              Text(item.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(item.path).textSelection(.enabled)
              if overview.ledger.wins.contains(where: { $0.paths.contains(item.path) }) {
                Text("Created again since cleanup").font(.caption).foregroundStyle(.orange)
              }
            }
            Spacer()
            Text("~\(ByteText.full(item.bytes))").monospacedDigit()
            Button("Finder") { reveal(item.path) }
            Toggle(
              "Select",
              isOn: Binding(
                get: { model.selectedPaths.contains(item.path) },
                set: { model.setSelected(StorageSelection(path: item.path, isSelected: $0)) })
            )
            .toggleStyle(.checkbox).disabled(model.isCleaning)
          }
        }
      }
    }
    .padding(18)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .task {
      while !Task.isCancelled {
        overview.refreshIfNeeded()
        do { try await Task.sleep(for: .seconds(60)) } catch { break }
      }
    }
    .sheet(item: $pendingFile) { file in
      VStack(alignment: .leading, spacing: 16) {
        Text("Delete this file permanently?").font(.title3.weight(.semibold))
        VStack(alignment: .leading, spacing: 6) {
          Text(file.name).font(.headline).textSelection(.enabled)
          Text(file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Text("\(file.kind) · \(ByteText.full(file.bytes)) on disk").font(.callout)
        }
        Text(
          "This skips Trash and cannot be undone. FreeSpace checks that the file is unchanged and closed."
        )
        .font(.callout).foregroundStyle(.secondary)
        if overview.deletingPath != nil {
          Text("This file will be queued. You can cancel it until deletion starts.")
            .font(.callout).foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button("Cancel", role: .cancel) { pendingFile = nil }
            .keyboardShortcut(.cancelAction)
          Button("Delete permanently", role: .destructive) {
            pendingFile = nil
            overview.delete(file)
          }
          .disabled(overview.isPending(file) || model.isCleaning)
        }
      }
      .padding(24)
      .frame(width: 520)
    }
  }

  private func fileRow(_ file: ReviewFile) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 14) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
          .resizable().frame(width: 32, height: 32)
        VStack(alignment: .leading, spacing: 5) {
          Text(file.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            .help(file.name)
          Text(file.path).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).help(file.path).textSelection(.enabled)
          Text(
            "\(file.kind) · \(file.isTemporary ? "Temporary location" : "Personal file") · modified \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 4) {
          Text(ByteText.full(file.bytes)).font(.title3.weight(.semibold)).monospacedDigit()
          Text("Review first").font(.caption).foregroundStyle(.orange)
        }
        Button("Finder") { reveal(file.path) }
        if overview.deletingPath == file.path {
          Text("Deleting…").font(.callout).foregroundStyle(.secondary)
        } else if overview.isPending(file) {
          Text("Queued").font(.callout).foregroundStyle(.secondary)
          Button("Cancel") { overview.cancelQueuedDeletion(file) }
        } else {
          Button(overview.deletionFailures[file.path] != nil ? "Try again…" : "Delete…") {
            pendingFile = file
          }
          .disabled(model.isCleaning)
        }
      }
      if let failure = overview.deletionFailures[file.path] {
        Label(failure, systemImage: "exclamationmark.triangle.fill")
          .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, 5)
  }

  private func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
}

struct CleanupTraySummary: View {
  @ObservedObject var overview: CleanupOverviewModel
  let openCleanup: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if overview.ledger.internalGains > 0 {
        Label(
          "\(ByteText.full(overview.ledger.internalGains)) gained in recorded cleanups",
          systemImage: "checkmark.circle"
        )
        .font(.caption).foregroundStyle(.green)
      }
      ForEach(overview.files.prefix(2)) { file in
        Button(action: openCleanup) {
          HStack {
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(ByteText.compact(file.bytes)).monospacedDigit()
          }
          .font(.caption)
        }.buttonStyle(.plain).help(file.path)
      }
      Button(action: openCleanup) {
        Label("Review files & cleanup wins", systemImage: "arrow.right.circle")
          .frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.link)
    }
    .task { overview.refreshIfNeeded() }
  }
}
