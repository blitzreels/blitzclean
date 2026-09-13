import AppKit
import SwiftUI

struct QuickCleanView: View {
  @ObservedObject var model: QuickCleanModel
  @ObservedObject var history: CleanupOverviewModel
  @State private var confirming = false
  @State private var reviewItems: [CacheCandidate] = []

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack {
            Text(
              model.scannedAt == nil
                ? "Caches"
                : "\(ByteText.full(model.totalBytes)) in \(model.candidates.count) caches"
            )
            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Spacer()
            Button(model.isScanning ? "Scanning…" : "Scan") { model.scan() }
              .disabled(model.isScanning || model.isCleaning)
          }
          if model.isScanning {
            HStack(spacing: 12) {
              ProgressView().controlSize(.small)
              Text("Checking known caches, ages, and running tools…").foregroundStyle(.secondary)
            }.padding(.vertical, 10)
          }
          if let status = model.status {
            Text(status).font(.callout).textSelection(.enabled).panelCard()
          }
          HStack {
            Text("Older than 7 days").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Select all") { model.selected = Set(model.candidates.map(\.path)) }
              .disabled(model.isScanning || model.isCleaning || model.candidates.isEmpty)
            Button("Clear") { model.selected = [] }.disabled(
              model.isCleaning || model.selected.isEmpty)
          }
          if model.candidates.isEmpty, !model.isScanning {
            ContentUnavailableView(
              "No older caches ready to clean", systemImage: "checkmark.shield",
              description: Text(
                "Recent caches and caches used by running tools are kept."
              )
            ).frame(maxWidth: .infinity)
          }
          LazyVStack(spacing: 0) {
            ForEach(model.candidates) { item in
              HStack(alignment: .top, spacing: 12) {
                Toggle(
                  "Select \(item.displayName)",
                  isOn: Binding(
                    get: { model.selected.contains(item.path) },
                    set: {
                      if $0 {
                        model.selected.insert(item.path)
                      } else {
                        model.selected.remove(item.path)
                      }
                    })
                ).labelsHidden().toggleStyle(.checkbox).disabled(
                  model.isScanning || model.isCleaning)
                VStack(alignment: .leading, spacing: 6) {
                  Text(item.displayName).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                  Text(item.rule.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }.help(item.rule.recipe + "\n" + item.path)
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                  Text(ByteText.full(item.tree.bytes)).font(.callout.weight(.semibold))
                    .monospacedDigit()
                  Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]
                    )
                  }
                  .controlSize(.small)
                }
              }.padding(.vertical, 12)
              Divider()
            }
          }
          if !model.notes.isEmpty {
            DisclosureGroup("Kept or skipped · \(model.notes.count)") {
              ForEach(Array(model.notes.enumerated()), id: \.offset) { note in
                Text(note.element).font(.caption).foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
              }
            }
          }

        }.padding(24)
      }
      Divider()
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(model.selectedItems.count) selected · \(ByteText.full(model.selectedBytes))")
            .font(.callout.weight(.semibold)).monospacedDigit()
          Text("Caches are deleted permanently and recreated by their tools.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if model.isCleaning { ProgressView().controlSize(.small) }
        Button(model.isCleaning ? "Cleaning…" : "Review cleanup…") {
          reviewItems = model.selectedItems
          confirming = true
        }.buttonStyle(BlitzButtonStyle(.accent)).controlSize(.large)
          .disabled(model.selectedItems.isEmpty || model.isCleaning || model.isScanning)
      }.padding(.horizontal, 24).padding(.vertical, 14).background(BlitzUI.sidebarBackground)
    }
    .task { if model.scannedAt == nil { model.scan() } }
    .sheet(isPresented: $confirming) {
      VStack(alignment: .leading, spacing: 20) {
        Text("Delete \(reviewItems.count) rebuildable caches?").font(.title2.bold())
        Text(
          "\(ByteText.full(reviewItems.reduce(0) { $0 + $1.tree.bytes })) will be checked for cleanup. This permanently removes the selected cache files; future downloads and builds can take longer."
        )
        .foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(reviewItems) { item in
              Text(item.rule.title + " / " + item.displayName).font(.callout).textSelection(
                .enabled)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 180)
        HStack {
          Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
          Spacer()
          Button("Delete selected caches", role: .destructive) {
            model.selected = Set(reviewItems.map(\.path))
            confirming = false
            model.clean(history: history)
          }.buttonStyle(BlitzButtonStyle(.secondary))
        }
      }.padding(24).frame(width: 520).blitzTheme()
    }
  }
}

struct LargeFileReviewView: View {
  @ObservedObject var model: CleanupOverviewModel
  @ObservedObject var monitor: SystemMonitor
  @State private var pending: ReviewFile?
  @State private var query = ""
  @State private var result: String?
  @State private var moving = false
  private var visibleFiles: [ReviewFile] {
    model.files.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
  }
  private var minimumMiB: Int { Int(model.reviewMinimumBytes / (1_024 * 1_024)) }
  private var folder: URL? {
    model.reviewRoots.count == 1 ? model.reviewRoots.first.map { URL(fileURLWithPath: $0) } : nil
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Text("Files stay recoverable in Trash.").font(.system(size: 12)).foregroundStyle(
            .secondary)
          Spacer()
          Button(model.isScanning ? "Cancel scan" : "Scan") {
            if model.isScanning { model.cancelScan() } else { model.refresh() }
          }.disabled(moving)
        }
        HStack {
          BlitzSearchField(title: "Search files", text: $query)
          Picker(
            "Larger than",
            selection: Binding(
              get: { minimumMiB },
              set: {
                configureScan(.init(folder: folder, minimumMiB: $0))
              })
          ) {
            Text("100 MiB").tag(100)
            Text("256 MiB").tag(256)
            Text("1 GiB").tag(1024)
          }.frame(width: 190).disabled(model.isScanning || moving)
          Button("Choose folder…") { chooseFolder() }.disabled(model.isScanning || moving)
        }
        if let folder {
          HStack {
            Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Button("Default folders") {
              configureScan(.init(folder: nil, minimumMiB: minimumMiB))
            }
            .disabled(model.isScanning || moving)
          }
        }
        if model.isScanning { ProgressView("Looking for large files…").frame(maxWidth: .infinity) }
        if let status = model.scanStatus {
          Text(status).font(.callout).foregroundStyle(.secondary)
        }
        if model.scanLimited, model.scanStatus == nil {
          Label(
            "Some folders were unreadable or reached the scan limit. Results are partial.",
            systemImage: "info.circle"
          )
          .font(.caption).foregroundStyle(.orange)
        }
        if let result { Text(result).font(.callout).textSelection(.enabled).panelCard() }
        if visibleFiles.isEmpty, !model.isScanning, model.scanStatus == nil {
          ContentUnavailableView(
            query.isEmpty ? "No large files found" : "No matching files",
            systemImage: "doc.text.magnifyingglass"
          ).frame(maxWidth: .infinity)
        }
        LazyVStack(spacing: 0) {
          ForEach(visibleFiles) { file in
            HStack(spacing: 14) {
              Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(
                width: 32, height: 32)
              VStack(alignment: .leading, spacing: 5) {
                Text(file.name).font(.callout.weight(.semibold)).lineLimit(2)
                Text(file.kind).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                  .truncationMode(.middle).textSelection(.enabled)
              }
              Spacer()
              VStack(alignment: .trailing, spacing: 8) {
                Text(ByteText.full(file.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                Text(file.modifiedAt, format: .dateTime.month().day().year()).font(.caption2)
                  .foregroundStyle(.secondary)
                HStack {
                  Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]
                    )
                  }
                  Button("Trash…") { pending = file }.disabled(moving)
                }.controlSize(.small)
              }
            }.padding(.vertical, 12)
            Divider()
          }
        }
      }.padding(24)
    }
    .task { model.refreshIfNeeded() }
    .confirmationDialog(
      "Move this file to Trash?",
      isPresented: Binding(
        get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible
    ) {
      if let file = pending {
        Button("Move to Trash", role: .destructive) {
          pending = nil
          trash(file)
        }
      }
      Button("Cancel", role: .cancel) { pending = nil }
    } message: {
      Text(
        (pending?.name ?? "")
          + " can be recovered from Trash. Disk space is reclaimed after you empty Trash in Finder."
      )
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose a folder on your Mac to review. External-drive files remain protected."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    configureScan(.init(folder: url, minimumMiB: minimumMiB))
  }

  private struct ScanSelection {
    let folder: URL?
    let minimumMiB: Int
  }

  private func configureScan(_ selection: ScanSelection) {
    model.configureReview(
      .init(
        roots: selection.folder.map { [$0.path] } ?? CleanupReviewScanner.roots,
        minimumBytes: UInt64(selection.minimumMiB) * 1_024 * 1_024, maxEntries: 80_000))
  }

  private func trash(_ file: ReviewFile) {
    moving = true
    let roots = model.reviewRoots
    Task {
      do {
        try await Task.detached(priority: .utility) {
          try ReviewFileDeletion.trash(.init(file: file, roots: roots))
        }.value
        result =
          "Moved \(file.name) to Trash. Restore it from Finder if needed; empty Trash in Finder when ready to reclaim disk space."
        model.synchronize()
        monitor.refresh()
      } catch { result = "Kept \(file.name). \(error.localizedDescription)" }
      moving = false
    }
  }
}
