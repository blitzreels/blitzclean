import AppKit
import SwiftUI

struct FolderExplorerView: View {
  @ObservedObject var model: FolderExplorerModel
  let onManageSimulators: () -> Void
  @State private var pendingTrash: [FolderEntry] = []
  @State private var visibleCount = 200
  @State private var largestFirst = true
  @State private var inspectedFile: FolderEntry?

  private var entries: [FolderEntry] {
    let visible = model.visibleEntries
    if largestFirst {
      return FolderListingSorter.sorted(visible.filter(\.isDirectory))
        + FolderListingSorter.sorted(visible.filter { !$0.isDirectory })
    }
    return visible.sorted {
      if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private var selected: [FolderEntry] {
    model.selected.isEmpty ? [] : model.entries.filter { model.selected.contains($0.path) }
  }

  var body: some View {
    let maximumBytes = model.maxBytes
    let entries = entries
    let selected = selected
    return VStack(spacing: 0) {
      toolbar
      columnHeader(entries)
      ScrollView {
        LazyVStack(spacing: 0) {
          if model.entries.isEmpty {
            Text(
              model.isScanning
                ? "Reading folder…"
                : model.statusMessage?.contains("unreadable") == true
                  || model.statusMessage == "This folder could not be read."
                  ? "No readable items in this folder" : "This folder is empty"
            )
            .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
            .padding(24).frame(maxWidth: .infinity)
          } else if entries.isEmpty {
            Text("No matching items").font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
              .padding(24)
          }
          ForEach(entries.prefix(visibleCount)) { entry in
            entryRow((entry: entry, maximumBytes: maximumBytes))
            BlitzRowDivider(leading: 58)
          }
          if entries.count > visibleCount {
            Button("Show more · \(entries.count.formatted()) items") { visibleCount += 200 }
              .blitzButton(.quiet).padding(12)
          }
        }.blitzTable().padding(.horizontal, BlitzUI.pagePadding).padding(.bottom, 16)
      }
      VStack(spacing: 8) {
        if let inspectedFile {
          HStack {
            Text(inspectedFile.path).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
              .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(inspectedFile.path)
            Spacer()
            Button("Show in Finder") { model.reveal(inspectedFile) }
              .blitzButton(.quiet).controlSize(.small)
          }
        }
        HStack {
          Text(
            selected.isEmpty
              ? "\(entries.count.formatted()) \(entries.count == 1 ? "item" : "items")"
              : "\(selected.count) selected"
          )
          .font(BlitzType.caption).monospacedDigit()
          Spacer()
          if model.isTrashing { ProgressView().controlSize(.small) }
          Button("Move to Trash…", role: .destructive) { pendingTrash = selected }
            .blitzButton(.secondary).disabled(selected.isEmpty || model.isTrashing)
        }
      }.padding(.horizontal, BlitzUI.pagePadding).padding(.vertical, 12).background(
        BlitzUI.panelBackground)
    }
    .task { model.loadIfNeeded() }
    .onChange(of: model.path) {
      visibleCount = 200
      inspectedFile = nil
    }
    .onChange(of: model.query) { visibleCount = 200 }
    .onDeleteCommand { pendingTrash = selected }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !pendingTrash.isEmpty {
        BlitzConfirmation(
          title: pendingTrash.count == 1
            ? "Move this item to Trash?" : "Move \(pendingTrash.count) items to Trash?",
          message: pendingTrash.prefix(4).map(\.name).joined(separator: ", ")
            + "\nFolders include all their contents. Restore from Trash if needed; empty it to reclaim space.",
          confirmTitle: "Move to Trash",
          onConfirm: {
            model.trash(pendingTrash)
            pendingTrash = []
            inspectedFile = nil
          },
          onCancel: { pendingTrash = [] })
      }
    }
  }

  private var toolbar: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Button("Back", systemImage: "chevron.left") { model.goBack() }
          .blitzButton(.quiet).disabled(model.backPaths.isEmpty)
          .help("Return to the previous folder in BlitzClean")
        if !model.forwardPaths.isEmpty {
          Button("Forward", systemImage: "chevron.right") { model.goForward() }
            .blitzButton(.quiet).help("Return to the next folder in BlitzClean")
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 2) {
            ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
              if index > 0 {
                Image(systemName: "chevron.right").font(.system(size: 9))
                  .foregroundStyle(BlitzUI.tertiaryText)
              }
              Button(crumb.title) { model.open(crumb.path) }
                .blitzButton(.quiet).controlSize(.small).fixedSize()
                .help("Open \(crumb.title) in BlitzClean")
            }
          }
        }
        Button {
          if model.isScanning { model.cancelScan() } else { model.rescan() }
        } label: {
          Label(
            model.isScanning ? "Stop" : "Refresh",
            systemImage: model.isScanning ? "xmark" : "arrow.clockwise")
        }.blitzButton(.quiet)
          .accessibilityLabel(model.isScanning ? "Stop measuring" : "Refresh folder")
          .help(model.isScanning ? "Stop measuring folder sizes" : "Refresh folder")
      }
      HStack(spacing: 8) {
        BlitzSearchField(title: "Search this folder", text: $model.query)
        Toggle("Hidden files", isOn: $model.showsHidden)
          .toggleStyle(BlitzCheckboxStyle()).font(BlitzType.label).fixedSize()
          .padding(.leading, 8)
      }
      if SimulatorDeviceService.isDevicePath(model.path) {
        HStack {
          Text("Delete simulated devices with Apple’s tools.")
            .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          Spacer()
          Button("Manage devices", action: onManageSimulators).blitzButton(.secondary)
        }
      }
      HStack(spacing: 6) {
        if model.isScanning {
          ProgressView().controlSize(.mini)
          Text("Measuring sizes · \(model.visited.formatted()) files checked")
        } else if let date = model.scannedAt {
          Text("Sizes from \(date.formatted(date: .omitted, time: .shortened))")
        }
        if let message = model.statusMessage {
          Text("·")
          Text(message).lineLimit(1).truncationMode(.tail).help(message)
            .textSelection(.enabled)
        }
        Spacer(minLength: 0)
      }.font(BlitzType.caption).monospacedDigit().foregroundStyle(BlitzUI.secondaryText)
        .frame(minHeight: 16)
    }.padding(.horizontal, BlitzUI.pagePadding).padding(.top, 12).padding(.bottom, 8)
  }

  private func columnHeader(_ entries: [FolderEntry]) -> some View {
    let selectable = Set(entries.filter(model.canTrash).map(\.path))
    return HStack(spacing: 0) {
      Toggle(
        "Select all visible items",
        isOn: Binding(
          get: { !selectable.isEmpty && selectable.isSubset(of: model.selected) },
          set: {
            if $0 {
              model.selected.formUnion(selectable)
            } else {
              model.selected.subtract(selectable)
            }
          }
        )
      ).toggleStyle(BlitzCheckboxStyle(showsLabel: false))
        .frame(width: 44, height: 34).disabled(selectable.isEmpty || model.isTrashing)
      Button(largestFirst ? "Name" : "Name ↑") { largestFirst = false }
        .blitzButton(.quiet).controlSize(.small)
      Spacer()
      Button(largestFirst ? "Size on disk ↓" : "Size on disk") { largestFirst = true }
        .blitzButton(.quiet).controlSize(.small)
        .padding(.trailing, 28)
    }.padding(.horizontal, BlitzUI.pagePadding)
  }

  private func entryRow(_ input: (entry: FolderEntry, maximumBytes: UInt64)) -> some View {
    let entry = input.entry
    return HStack(spacing: 0) {
      Toggle(
        "Select \(entry.name)",
        isOn: Binding(
          get: { model.selected.contains(entry.path) },
          set: {
            if $0 { model.selected.insert(entry.path) } else { model.selected.remove(entry.path) }
          }
        )
      ).toggleStyle(BlitzCheckboxStyle(showsLabel: false))
        .frame(width: 44, height: 52)
        .disabled(!model.canTrash(entry) || model.isTrashing)
      Button {
        if entry.isDirectory {
          model.open(entry.path)
        } else {
          inspectedFile = entry
          if model.canTrash(entry) {
            if model.selected.contains(entry.path) {
              model.selected.remove(entry.path)
            } else {
              model.selected.insert(entry.path)
            }
          }
        }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
            .font(.system(size: 20)).foregroundStyle(BlitzUI.secondaryText).frame(width: 24)
          Text(entry.name).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          GeometryReader { geometry in
            let fraction =
              input.maximumBytes == 0
              ? 0 : min(1, Double(entry.bytes ?? 0) / Double(input.maximumBytes))
            Capsule().fill(BlitzUI.mint.opacity(0.1))
              .overlay(alignment: .leading) {
                Capsule().fill(BlitzUI.mint.opacity(0.65))
                  .frame(width: geometry.size.width * fraction)
              }
          }.frame(width: 84, height: 4).allowsHitTesting(false).accessibilityHidden(true)
          Text(
            entry.bytes.map {
              (entry.sizeEstimate == .minimum ? "≥ " : entry.sizeEstimate == .previous ? "~ " : "")
                + ByteText.full($0)
            }
              ?? (model.isScanning ? "Measuring…" : "Unreadable")
          )
          .font(BlitzType.numeric).monospacedDigit().foregroundStyle(BlitzUI.supportingText)
          .frame(minWidth: 92, alignment: .trailing)
          Image(systemName: entry.isDirectory ? "chevron.right" : "doc.text")
            .font(.system(size: 11)).foregroundStyle(BlitzUI.secondaryText).frame(width: 16)
        }.padding(.leading, 4).padding(.trailing, 16)
          .frame(minHeight: 52).contentShape(Rectangle())
      }.buttonStyle(BlitzRowButtonStyle()).disabled(model.isTrashing)
        .accessibilityLabel(entry.isDirectory ? "Open \(entry.name)" : "Select \(entry.name)")
        .help(entry.isDirectory ? "Open folder" : entry.path)
    }
    .background(model.selected.contains(entry.path) ? BlitzUI.selectedFill : .clear)
    .contextMenu {
      if entry.isDirectory { Button("Open folder") { model.open(entry.path) } }
      Button("Show in Finder") { model.reveal(entry) }
      if model.canTrash(entry) {
        Button("Move to Trash…", role: .destructive) { pendingTrash = [entry] }
      }
    }
  }
}
