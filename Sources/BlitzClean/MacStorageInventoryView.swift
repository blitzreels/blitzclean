import AppKit
import SwiftUI

struct MacStorageInventoryView: View {
  @ObservedObject var model: StorageBreakdownModel
  let onBrowse: (String) -> Void
  @State private var query = ""
  @State private var showingAll: Set<String> = []
  @State private var pendingApp: StorageItem?
  @State private var status: Status?

  private struct Status {
    let text: String
    let tone: BlitzStatusTone
  }

  private struct Section: Identifiable {
    let category: StorageCategory
    let items: [StorageItem]
    var id: String { category.id }
    var isDeveloper: Bool { !category.id.hasPrefix("computer-") && category.id != "large-files" }
  }

  private static let order = [
    "computer-applications", "computer-xcode", "computer-user-caches", "large-files",
    "computer-personal-files", "computer-library-data", "computer-system-data", "node-modules",
  ]

  /// Sorted, query-filtered sections computed once per render.
  private var sections: [Section] {
    model.categories.filter { !$0.items.isEmpty }
      .sorted { left, right in
        let leftIndex = Self.order.firstIndex(of: left.id) ?? Self.order.count
        let rightIndex = Self.order.firstIndex(of: right.id) ?? Self.order.count
        return leftIndex == rightIndex ? left.bytes > right.bytes : leftIndex < rightIndex
      }
      .map { category in
        let sorted = category.items.sorted { $0.bytes > $1.bytes }
        return Section(
          category: category,
          items: query.isEmpty
            ? sorted
            : sorted.filter {
              $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
            })
      }
      .filter { query.isEmpty || !$0.items.isEmpty }
  }

  var body: some View {
    let sections = sections
    let developer = sections.filter(\.isDeveloper)
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        HStack {
          BlitzSearchField(title: "Search apps, files, and folders", text: $query)
          Button("Browse folders") {
            onBrowse(FileManager.default.homeDirectoryForCurrentUser.path)
          }.blitzButton(.quiet)
          Button("Scan Mac") { model.scan() }.blitzButton(.secondary)
            .disabled(model.isScanning)
        }
        HStack(spacing: 8) {
          if model.isScanning {
            ProgressView().controlSize(.small)
            Text("Measuring apps and folders…")
          } else if let scannedAt = model.scannedAt {
            Text("Scanned \(scannedAt.formatted(date: .abbreviated, time: .shortened))")
              .help(
                "Allocated disk space. Categories can overlap. Protected locations require Full Disk Access; large files use Spotlight."
              )
          }
        }.font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        if let status { BlitzStatusLine(text: status.text, tone: status.tone) }
        if sections.isEmpty && !model.isScanning {
          BlitzEmptyRow(
            text: query.isEmpty
              ? "No inventory yet. Scan Mac to measure apps and folders."
              : "Nothing named \(query) found",
            isLoading: false)
        }
        inventorySections(sections.filter { !$0.isDeveloper })
        if !developer.isEmpty {
          Text("Developer data").font(BlitzType.section).foregroundStyle(BlitzUI.secondaryText)
            .padding(.top, 8)
          inventorySections(developer)
        }
      }.padding(BlitzUI.pagePadding)
    }
    .task { model.scanIfNeeded() }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let pendingApp {
        BlitzConfirmation(
          title: "Move \(pendingApp.name) to Trash?",
          message:
            "Moves the app bundle only. Support files may remain. Empty Trash to reclaim space.",
          confirmTitle: "Move app to Trash",
          onConfirm: {
            let app = pendingApp
            self.pendingApp = nil
            trash(app)
          }, onCancel: { self.pendingApp = nil })
      }
    }
  }

  private func inventorySections(_ sections: [Section]) -> some View {
    ForEach(sections) { section in
      let expanded = !query.isEmpty || showingAll.contains(section.id)
      let displayed = expanded ? section.items : Array(section.items.prefix(6))
      BlitzStorageSection(
        title: section.category.name, symbol: section.category.systemImage,
        detail: section.category.detail, trailing: ByteText.full(section.category.bytes),
        showsContent: true
      ) {
        LazyVStack(spacing: 0) {
          ForEach(displayed) { item in
            itemRow(.init(item: item, category: section.category))
            if item.id != displayed.last?.id { BlitzRowDivider(leading: 54) }
          }
          if query.isEmpty && section.items.count > 6 {
            BlitzRowDivider(leading: 0)
            BlitzShowAllButton(
              total: section.items.count, noun: "items",
              isExpanded: Binding(
                get: { showingAll.contains(section.id) },
                set: {
                  if $0 { showingAll.insert(section.id) } else { showingAll.remove(section.id) }
                }
              )
            ).padding(.vertical, 8)
          }
        }
      }
    }
  }

  private struct RowInput {
    let item: StorageItem
    let category: StorageCategory
  }

  private func itemRow(_ input: RowInput) -> some View {
    let item = input.item
    let category = input.category
    return HStack(spacing: 12) {
      if category.id == "computer-applications" {
        ApplicationIcon(source: .file(item.path), size: 26, fallback: "app")
      } else {
        Image(systemName: category.id == "large-files" ? "doc" : "folder")
          .frame(width: 26).foregroundStyle(BlitzUI.secondaryText)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(item.name).font(BlitzType.rowTitle).lineLimit(1)
        Text(item.path).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      }.frame(maxWidth: .infinity, alignment: .leading)
      BlitzTrailingValue(value: ByteText.full(item.bytes), detail: nil)
      Button("Show in Finder") { Finder.reveal(item.path) }.blitzButton(.quiet)
        .controlSize(.small)
      if !item.path.hasSuffix(".app"), DirectoryCheck.isDirectory(item.path) {
        Button("Browse") { onBrowse(item.path) }.blitzButton(.secondary).controlSize(.small)
      } else if category.id == "computer-applications", canTrash(item) {
        BlitzActionMenu(label: "Actions for \(item.name)") {
          Button("Move app to Trash…", role: .destructive) { pendingApp = item }
        }
      }
    }.blitzRow()
  }

  private func canTrash(_ item: StorageItem) -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return item.path.hasSuffix(".app")
      && (item.path.hasPrefix("/Applications/")
        || item.path.hasPrefix(home + "/Applications/"))
  }

  private func trash(_ item: StorageItem) {
    guard canTrash(item),
      ReviewFile.canonicalPath(item.path) == item.path,
      FileManager.default.fileExists(atPath: item.path)
    else {
      status = .init(
        text: "The app moved or changed. Scan again before uninstalling.", tone: .warning)
      return
    }
    let running = NSWorkspace.shared.runningApplications.contains { app in
      app.bundleURL?.path == item.path
    }
    guard !running else {
      status = .init(text: "Quit \(item.name) before uninstalling it.", tone: .warning)
      return
    }
    do {
      try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
      status = .init(
        text: "\(item.name) moved to Trash. Empty Trash to reclaim space.", tone: .working)
      model.scan()
    } catch {
      status = .init(
        text: "Could not move \(item.name) to Trash: \(error.localizedDescription)", tone: .warning)
    }
  }
}

/// Remembers whether an inventory path is a folder, so rows avoid a file-system call per render.
@MainActor
private enum DirectoryCheck {
  private static var cache: [String: Bool] = [:]

  static func isDirectory(_ path: String) -> Bool {
    if let known = cache[path] { return known }
    let value =
      (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
      == true
    if cache.count > 4_000 { cache.removeAll() }
    cache[path] = value
    return value
  }
}
