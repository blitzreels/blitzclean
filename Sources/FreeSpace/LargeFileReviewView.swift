import AppKit
import SwiftUI

struct LargeFileReviewView: View {
  @ObservedObject var model: CleanupOverviewModel
  @ObservedObject var monitor: SystemMonitor
  @StateObject private var media = MediaLibraryModel.application
  @State private var duplicateOnly = false
  @State private var showingFilters = false
  @State private var pendingTrash: [ReviewFile] = []
  @State private var pendingExport: [ReviewFile] = []
  @State private var moving = false
  @State private var result: String?
  @State private var visibleCount = 200

  private var duplicatePaths: Set<String> { Set(media.duplicates.flatMap { $0.files.map(\.path) }) }
  private var visibleFiles: [ReviewFile] {
    model.mediaFilter.apply(.init(files: model.files, date: .now))
      .filter { !duplicateOnly || duplicatePaths.contains($0.path) }
  }
  private var selectedFiles: [ReviewFile] {
    model.files.filter { media.selected.contains($0.path) }
  }
  private var busy: Bool {
    moving || media.isExporting || media.isFindingDuplicates || model.isScanning
  }
  private var minimumMiB: Int { Int(model.reviewMinimumBytes / (1_024 * 1_024)) }

  var body: some View {
    Group {
      if !pendingExport.isEmpty {
        MediaExportSheet(
          input: .init(
            files: pendingExport, roots: model.reviewRoots, media: media,
            onClose: { pendingExport = [] }))
      } else {
        fileBrowser
      }
    }
  }

  private var fileBrowser: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          DriveSourceBrowser(
            model: model, blocked: moving || media.isExporting || media.isFindingDuplicates)
          filterControls
          if let error = model.reviewPersistenceError {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(
              .orange)
          }
          scanProgress
          if model.scanLimited && model.driveProgress == nil {
            Text("Showing saved results. Scan again to update every accessible location.")
              .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          }
          if let status = result ?? media.status ?? model.scanStatus {
            Text(status).font(.system(size: 12)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading).panelCard()
          }
          HStack {
            Text(
              "Largest files · \(visibleFiles.count) results"
            )
            .font(.system(size: 12, weight: .medium)).monospacedDigit()
            Spacer()
            if !media.duplicates.isEmpty {
              Toggle("Duplicates only", isOn: $duplicateOnly).toggleStyle(BlitzCheckboxStyle())
                .font(.system(size: 11))
              Button("Select extra copies") { media.selectExtraCopies() }.controlSize(.small)
                .disabled(busy)
            }
          }
          if visibleFiles.isEmpty, !model.isScanning {
            VStack(spacing: 12) {
              Text("No files match the current filters.").font(BlitzType.body)
              Button("Show all sizes and types") {
                model.mediaFilter = MediaReviewFilter()
                duplicateOnly = false
                model.configureReview(
                  .init(
                    roots: model.reviewRoots, minimumBytes: 0, maxEntries: 80_000,
                    entireHierarchy: true))
              }.blitzButton(.secondary)
            }.frame(maxWidth: .infinity)
          }
          LazyVStack(spacing: 0) {
            ForEach(visibleFiles.prefix(visibleCount)) { file in fileRow(file) }
          }.blitzTable()
          if visibleFiles.count > visibleCount {
            Button("Show more files") { visibleCount += 200 }.blitzButton(.quiet)
          }
          if !media.exports.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
              Text("Recent exports · \(media.exports.count)")
                .font(.system(size: 13, weight: .semibold)).padding(.bottom, 6)
              ForEach(media.exports.prefix(10)) { export in
                HStack {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: export.output).lastPathComponent).font(
                      .system(size: 12))
                    Text("\(export.kind) · \(ByteText.full(UInt64(export.outputBytes)))")
                      .font(.system(size: 10)).foregroundStyle(.secondary)
                  }
                  Spacer()
                  Button("Reveal") { media.reveal(export) }.controlSize(.small)
                }.padding(.vertical, 6)
              }
            }.font(.system(size: 12))
          }
        }.padding(24)
      }
      Divider()
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(selectedFiles.count) selected").font(.system(size: 12, weight: .semibold))
        }
        Spacer()
        if media.isExporting || media.isFindingDuplicates {
          ProgressView().controlSize(.small)
          Button("Cancel") { media.cancel() }
        } else {
          BlitzActionMenu(label: "Media tools", title: "Media tools") {
            Button("Find duplicates") {
              result = nil
              media.findDuplicates(visibleFiles)
            }.disabled(busy || visibleFiles.isEmpty)
            Button("Export or join selected files…") {
              result = nil
              pendingExport = selectedFiles.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
              }
            }.disabled(busy || selectedFiles.isEmpty || selectedFiles.count > 20)
          }.fixedSize()
          Button("Move to Trash…", role: .destructive) { pendingTrash = selectedFiles }
            .disabled(busy || selectedFiles.isEmpty)
        }
      }.padding(.horizontal, 24).padding(.vertical, 14).background(BlitzUI.cardFill)
    }
    .task { model.refreshIfNeeded() }
    .onChange(of: model.scannedAt) { _, _ in
      media.invalidateDuplicates()
      duplicateOnly = false
      media.selected.formIntersection(Set(model.files.map(\.path)))
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !pendingTrash.isEmpty {
        BlitzConfirmation(
          title: "Move \(pendingTrash.count) files to Trash?",
          message:
            "Files remain recoverable in Finder's Trash. Space is reclaimed only after emptying Trash.",
          confirmTitle: "Move to Trash",
          onConfirm: {
            let files = pendingTrash
            pendingTrash = []
            trash(files)
          }, onCancel: { pendingTrash = [] })
      }
    }
  }

  @ViewBuilder private var scanProgress: some View {
    if let progress = model.driveProgress {
      HStack(spacing: 8) {
        if model.isScanning { ProgressView().controlSize(.small) }
        VStack(alignment: .leading, spacing: 3) {
          Text(
            "\(progress.visited.formatted()) files checked · \(progress.complete ? "scan finished" : model.isScanning ? "scanning" : "scan stopped")"
          )
          .font(BlitzType.caption).monospacedDigit()
          if model.isScanning {
            Text(progress.currentPath).font(BlitzType.caption)
              .foregroundStyle(BlitzUI.secondaryText).lineLimit(1).truncationMode(.middle)
          }
        }
        Spacer()
        Text("\(Int(progress.elapsed))s").font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.secondaryText)
      }
      if progress.unreadable > 0 {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("\(progress.unreadable.formatted()) locations could not be read")
              .font(BlitzType.caption).foregroundStyle(BlitzUI.warning)
            Spacer()
            Button("Full Disk Access…") {
              if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
              {
                NSWorkspace.shared.open(url)
              }
            }.blitzButton(.quiet)
          }
          Text(progress.unreadablePaths.prefix(3).joined(separator: " · "))
            .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            .lineLimit(2).textSelection(.enabled)
        }
      }
      if progress.files.count == 5_000 {
        Text("Showing the 5,000 largest files found. Browse a folder to narrow the results.")
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
    } else if model.isScanning {
      ProgressView("Reading drives…").controlSize(.small)
    } else if let date = model.scannedAt {
      Text("Saved scan · \(date.formatted(date: .abbreviated, time: .shortened))")
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
    }
  }

  private var filterControls: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        BlitzSearchField(title: "Search file names or paths", text: $model.mediaFilter.query)
        Button {
          showingFilters.toggle()
        } label: {
          Label(
            showingFilters ? "Hide filters" : "Filters", systemImage: "line.3.horizontal.decrease")
        }
      }
      Text(
        "\(model.mediaFilter.kind.rawValue) · \(minimumMiB == 0 ? "Any size" : "\(minimumMiB) MB+") · \(model.mediaFilter.sort.rawValue)"
      )
      .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      if showingFilters {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("File filters").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Reset filters") {
              model.mediaFilter = MediaReviewFilter()
              duplicateOnly = false
              model.configureReview(
                .init(
                  roots: model.reviewRoots, minimumBytes: 100 * 1_024 * 1_024, maxEntries: 80_000,
                  entireHierarchy: true))
            }.disabled(busy)
          }
          HStack(alignment: .top, spacing: 16) {
            filterField(
              .init(
                title: "Type",
                content: AnyView(
                  BlitzSegmentedPicker(
                    title: "File type", options: ReviewMediaKind.allCases,
                    selection: $model.mediaFilter.kind, label: { $0.rawValue }))))
            filterField(
              .init(
                title: "Minimum size",
                content: AnyView(
                  BlitzSegmentedPicker(
                    title: "Minimum size", options: [0, 100, 256, 1024],
                    selection: Binding(
                      get: { minimumMiB },
                      set: {
                        model.configureReview(
                          .init(
                            roots: model.reviewRoots, minimumBytes: UInt64($0) * 1_024 * 1_024,
                            maxEntries: 80_000, entireHierarchy: true))
                      }), label: { $0 == 0 ? "Any size" : $0 == 1024 ? "1 GB" : "\($0) MB" }
                  ).disabled(busy))))
          }
          HStack(alignment: .top, spacing: 16) {
            filterField(
              .init(
                title: "Modified",
                content: AnyView(
                  BlitzSegmentedPicker(
                    title: "Modified", options: ReviewMediaAge.allCases,
                    selection: $model.mediaFilter.age,
                    label: {
                      $0 == .any ? "Any age" : $0 == .year ? "1+ year" : "\($0.rawValue)+ days"
                    }
                  ))))
            filterField(
              .init(
                title: "Sort",
                content: AnyView(
                  BlitzSegmentedPicker(
                    title: "Sort", options: ReviewMediaSort.allCases,
                    selection: $model.mediaFilter.sort,
                    label: { $0 == .name ? "Name" : String($0.rawValue.dropLast(6)) }))))
          }
          filterField(
            .init(
              title: "Format",
              content: AnyView(
                BlitzSegmentedPicker(
                  title: "Format",
                  options: [
                    "all", "mp4", "mov", "m4v", "mkv", "webm", "png", "jpg", "jpeg", "heic", "gif",
                    "tiff", "webp",
                  ],
                  selection: $model.mediaFilter.format,
                  label: { $0 == "all" ? "All" : "." + $0 }))))
        }.panelCard()
      }
    }
  }

  private struct FilterField {
    let title: String
    let content: AnyView
  }

  private func filterField(_ input: FilterField) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(input.title).font(.system(size: 11)).foregroundStyle(.secondary)
      input.content
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func fileRow(_ file: ReviewFile) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Toggle(
          "Select \(file.name)",
          isOn: Binding(
            get: { media.selected.contains(file.path) },
            set: {
              if $0 { media.selected.insert(file.path) } else { media.selected.remove(file.path) }
            })
        )
        .toggleStyle(BlitzCheckboxStyle(showsLabel: false))
        .disabled(busy || !ReviewFileDeletion.canTrashPath(file.path))
        .help(
          ReviewFileDeletion.canTrashPath(file.path)
            ? "Select file" : "System or app file · view only")
        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(
          width: 30, height: 30)
        VStack(alignment: .leading, spacing: 4) {
          Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(
            .middle)
          Text(file.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            .truncationMode(.middle)
          if duplicatePaths.contains(file.path) {
            Text("Exact duplicate").font(.system(size: 10)).foregroundStyle(BlitzUI.lavender)
          }
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 4) {
          Text(ByteText.full(file.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
          Text(file.modifiedAt, format: .dateTime.month().day().year()).font(.system(size: 10))
            .foregroundStyle(.secondary)
        }.frame(minWidth: 80)
        Button("Show in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
        }
        .controlSize(.small)
      }.blitzRow()
      BlitzRowDivider(leading: 76)
    }
  }

  private func trash(_ files: [ReviewFile]) {
    let selected = Set(files.map(\.path))
    let groups = media.duplicates.filter { $0.files.contains { selected.contains($0.path) } }
    let keepers = groups.compactMap { group in group.files.first { !selected.contains($0.path) } }
    guard groups.count == keepers.count else {
      result = "Keep at least one file from each duplicate group."
      return
    }
    moving = true
    let roots = model.reviewRoots
    Task {
      let message = await Task.detached(priority: .utility) {
        var moved = 0
        var failures: [String] = []
        for file in files {
          do {
            for keeper in keepers {
              try ReviewFileDeletion.validateIdentity(.init(file: keeper, roots: roots))
            }
            try ReviewFileDeletion.trash(.init(file: file, roots: roots))
            moved += 1
          } catch { failures.append("\(file.name): \(error.localizedDescription)") }
        }
        return "Moved \(moved) of \(files.count) files to Trash. "
          + failures.prefix(3).joined(separator: " ")
      }.value
      result = message
      media.selected = []
      media.invalidateDuplicates()
      duplicateOnly = false
      model.synchronize()
      monitor.refresh()
      moving = false
    }
  }
}
