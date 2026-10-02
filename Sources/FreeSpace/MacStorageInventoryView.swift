import AppKit
import SwiftUI

struct MacStorageInventoryView: View {
  @ObservedObject var model: StorageBreakdownModel
  let onBrowse: (String) -> Void
  @State private var query = ""
  @State private var showingAll: Set<String> = []
  @State private var pendingApp: StorageItem?
  @State private var status: String?

  private var categories: [StorageCategory] {
    let order = [
      "computer-applications", "computer-xcode", "computer-user-caches", "large-files",
      "computer-personal-files", "computer-library-data", "computer-system-data", "node-modules",
    ]
    return model.categories.filter { !$0.items.isEmpty }.sorted { left, right in
      let leftIndex = order.firstIndex(of: left.id) ?? order.count
      let rightIndex = order.firstIndex(of: right.id) ?? order.count
      return leftIndex == rightIndex ? left.bytes > right.bytes : leftIndex < rightIndex
    }
  }

  private func items(in category: StorageCategory) -> [StorageItem] {
    let sorted = category.items.sorted { $0.bytes > $1.bytes }
    guard !query.isEmpty else { return sorted }
    return sorted.filter {
      $0.name.localizedCaseInsensitiveContains(query)
        || $0.path.localizedCaseInsensitiveContains(query)
    }
  }

  private var matchingCategories: [StorageCategory] {
    categories.filter { query.isEmpty || !items(in: $0).isEmpty }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          BlitzSearchField(title: "Search apps, files, and folders", text: $query)
          Button("Browse folders") {
            onBrowse(FileManager.default.homeDirectoryForCurrentUser.path)
          }
          Button("Scan Mac") { model.scan() }
            .disabled(model.isScanning)
        }
        if let scannedAt = model.scannedAt {
          Text(
            "Scanned \(scannedAt.formatted(date: .abbreviated, time: .shortened))"
          )
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .help(
            "Allocated disk space. Categories can overlap. Protected locations require Full Disk Access; large files use Spotlight."
          )
        }
        if model.isScanning {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Measuring apps and folders…")
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
        if let status {
          Text(status).font(.system(size: 12)).textSelection(.enabled)
            .foregroundStyle(.orange)
        }
        if categories.isEmpty && !model.isScanning {
          ContentUnavailableView(
            "No inventory yet", systemImage: "internaldrive",
            description: Text("Scan Mac to see installed apps and the largest folders."))
        }
        if !query.isEmpty && matchingCategories.isEmpty && !model.isScanning {
          ContentUnavailableView(
            "Nothing named \(query) found", systemImage: "magnifyingglass",
            description: Text("Check the scan time, or search another app, file, or folder name."))
        }
        inventorySections(
          matchingCategories.filter { $0.id.hasPrefix("computer-") || $0.id == "large-files" })
        let developerCategories = matchingCategories.filter {
          !$0.id.hasPrefix("computer-") && $0.id != "large-files"
        }
        if !developerCategories.isEmpty {
          Text("Developer data").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary).padding(.top, 8)
          inventorySections(developerCategories)
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

  private func inventorySections(_ categories: [StorageCategory]) -> some View {
    ForEach(categories) { category in
      let visible = items(in: category)
      let displayed =
        query.isEmpty && !showingAll.contains(category.id)
        ? Array(visible.prefix(6)) : visible
      if query.isEmpty || !visible.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 10) {
            Image(systemName: category.systemImage).frame(width: 20)
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(category.name).font(.system(size: 14, weight: .semibold))
              Text("\(category.items.count) items")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteText.full(category.bytes)).font(.system(size: 12, weight: .semibold))
              .monospacedDigit()
          }.help(category.detail).accessibilityAddTraits(.isHeader)
          LazyVStack(spacing: 0) {
            ForEach(displayed) { item in
              itemRow(.init(item: item, category: category))
              if item.id != displayed.last?.id { Divider() }
            }
            if query.isEmpty && visible.count > 6 {
              Button(
                showingAll.contains(category.id)
                  ? "Show fewer" : "Show all \(visible.count) items"
              ) {
                if showingAll.contains(category.id) {
                  showingAll.remove(category.id)
                } else {
                  showingAll.insert(category.id)
                }
              }
              .controlSize(.small)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 10)
            }
          }.padding(.top, 8)
        }
        .panelCard()
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
        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
          .resizable().frame(width: 26, height: 26)
      } else {
        Image(systemName: category.id == "large-files" ? "doc" : "folder")
          .frame(width: 26).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
        Text(item.path).font(.system(size: 10)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      }
      Spacer(minLength: 12)
      Text(ByteText.full(item.bytes)).font(.system(size: 12, weight: .medium))
        .monospacedDigit()
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
      }.controlSize(.small)
      if !item.path.hasSuffix(".app"),
        (try? URL(fileURLWithPath: item.path).resourceValues(forKeys: [.isDirectoryKey]))?
          .isDirectory == true
      {
        Button("Browse") { onBrowse(item.path) }.controlSize(.small)
      } else if category.id == "computer-applications", canTrash(item) {
        BlitzActionMenu(label: "Actions for \(item.name)") {
          Button("Move app to Trash…", role: .destructive) { pendingApp = item }
        }
      }
    }.padding(.vertical, 10)
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
      status = "The app moved or changed. Scan again before uninstalling."
      return
    }
    let running = NSWorkspace.shared.runningApplications.contains { app in
      app.bundleURL?.path == item.path
    }
    guard !running else {
      status = "Quit \(item.name) before uninstalling it."
      return
    }
    do {
      try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
      status = "\(item.name) moved to Trash. Empty Trash to reclaim space."
      model.scan()
    } catch {
      status = "Could not move \(item.name) to Trash: \(error.localizedDescription)"
    }
  }
}
