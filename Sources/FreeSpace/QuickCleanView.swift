import AppKit
import SwiftUI

struct QuickCleanView: View {
  @ObservedObject var model: QuickCleanModel
  @ObservedObject var history: CleanupOverviewModel
  @State private var pendingReview: CacheCleanupReview?

  private struct CacheCleanupReview: Identifiable {
    let id = UUID()
    let items: [CacheCandidate]
  }

  var body: some View {
    VStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          Text("Unused for at least 7 days")
            .font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
          Button("Scan caches") { model.scan() }
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
        if model.candidates.isEmpty, !model.isScanning {
          Text("Nothing older than 7 days. Caches used by running tools are kept.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if !model.candidates.isEmpty {
          HStack {
            Toggle(
              "Select all",
              isOn: Binding(
                get: {
                  !model.candidates.isEmpty && model.selectedItems.count == model.candidates.count
                },
                set: { model.selected = $0 ? Set(model.candidates.map(\.path)) : [] }
              )
            ).toggleStyle(BlitzCheckboxStyle())
              .disabled(model.isScanning || model.isCleaning || model.candidates.isEmpty)
            Spacer()
          }.font(.system(size: 12))
          LazyVStack(spacing: 0) {
            ForEach(model.candidates) { item in
              HStack(spacing: 12) {
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
                ).toggleStyle(BlitzCheckboxStyle(showsLabel: false)).disabled(
                  model.isScanning || model.isCleaning)
                ApplicationIcon(source: .file(item.path), size: 28, fallback: "folder")
                VStack(alignment: .leading, spacing: 6) {
                  Text(item.displayName).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                  Text(item.rule.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }.help(item.rule.recipe + "\n" + item.path)
                Spacer()
                Text(ByteText.full(item.tree.bytes)).font(.system(size: 12, weight: .medium))
                  .monospacedDigit()
                Button("Show in Finder") {
                  NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]
                  )
                }
                .controlSize(.small)
              }.blitzRow()
              if item.id != model.candidates.last?.id { BlitzRowDivider(leading: 44) }
            }
          }.blitzTable()
        }
        if !model.notes.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            Text("Kept or skipped · \(model.notes.count)")
              .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(model.notes.enumerated()), id: \.offset) { note in
              Text(note.element).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
          }
        }

      }
      if !model.candidates.isEmpty || model.isCleaning {
        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("\(model.selectedItems.count) selected · \(ByteText.full(model.selectedBytes))")
              .font(.callout.weight(.semibold)).monospacedDigit()
          }
          Spacer()
          if model.isCleaning { ProgressView().controlSize(.small) }
          Button("Review cleanup…") {
            let items = model.selectedItems
            guard !items.isEmpty else { return }
            pendingReview = CacheCleanupReview(items: items)
          }.buttonStyle(BlitzButtonStyle(.accent)).controlSize(.large)
            .disabled(model.selectedItems.isEmpty || model.isCleaning || model.isScanning)
        }
      }
      if let review = pendingReview {
        BlitzConfirmation(
          title: "Delete \(review.items.count) rebuildable caches?",
          message:
            "\(ByteText.full(review.items.reduce(0) { $0 + $1.tree.bytes })) will be checked for cleanup. This permanently removes the selected cache files; future downloads and builds can take longer.\n\n"
            + review.items.map { $0.rule.title + " / " + $0.displayName }.joined(separator: "\n"),
          confirmTitle: "Delete selected caches",
          onConfirm: {
            model.selected = Set(review.items.map(\.path))
            pendingReview = nil
            model.clean(history: history)
          }, onCancel: { pendingReview = nil })
      }
    }.padding(16)
      .task { if model.scannedAt == nil { model.scan() } }
  }
}
