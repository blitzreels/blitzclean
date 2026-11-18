import SwiftUI

struct QuickCleanView: View {
  @ObservedObject var model: QuickCleanModel
  @ObservedObject var history: CleanupOverviewModel
  @State private var review: [CacheCandidate] = []
  @State private var choosing = false
  @State private var showsNotes = false

  var body: some View {
    let caches = model.quickCandidates
    let custom = choosing || caches.isEmpty
    let items = custom ? model.selectedItems : caches
    let locked = model.isBusy || !review.isEmpty
    VStack(spacing: 0) {
      if model.scannedAt == nil || (model.isScanning && model.candidates.isEmpty) {
        BlitzEmptyRow(text: "Checking cache folders and reports…", isLoading: true)
      } else if model.candidates.isEmpty && model.status == nil {
        BlitzEmptyRow(text: "No eligible caches or reports found", isLoading: false)
      }
      if let status = model.status {
        BlitzStatusLine(text: status, tone: .working).padding(16)
      }
      if !model.candidates.isEmpty {
        HStack(spacing: 10) {
          if !caches.isEmpty {
            Button(choosing ? "Back to caches" : "Choose items") { choosing.toggle() }
              .blitzButton(.quiet).disabled(locked)
          }
          Spacer()
          Button {
            review = items
          } label: {
            BlitzActionLabel(
              title: (custom ? "Review selection" : "Review caches")
                + (items.isEmpty
                  ? "" : " · " + ByteText.compact(items.reduce(0) { $0 + $1.tree.bytes })))
          }.blitzButton(.accent).disabled(locked || items.isEmpty)
        }.padding(12)
      }
      if !review.isEmpty {
        let bytes = review.reduce(0) { $0 + $1.tree.bytes }
        let includesReports = review.contains { $0.rule.kind == .diagnosticReport }
        let note =
          includesReports
          ? "Selected reports are permanently deleted. Apps can rebuild their caches."
          : "Apps can rebuild these caches. Downloads and builds may take longer next time."
        BlitzConfirmation(
          title: "Delete \(ByteText.compact(bytes))?",
          message: review.map {
            "\($0.rule.title) / \($0.displayName) · \(ByteText.full($0.tree.bytes))"
          }
          .joined(separator: "\n") + "\n\n" + note,
          confirmTitle: "Delete \(review.count) \(review.count == 1 ? "item" : "items")",
          onConfirm: {
            model.cleanReviewed(.init(items: review, history: history))
            review = []
          }, onCancel: { review = [] })
      }
      if custom && !model.candidates.isEmpty {
        Toggle(
          "Select all",
          isOn: Binding(
            get: { model.selectedItems.count == model.candidates.count },
            set: { model.selected = $0 ? Set(model.candidates.map(\.path)) : [] })
        ).toggleStyle(BlitzCheckboxStyle()).font(BlitzType.label).disabled(locked)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
        LazyVStack(spacing: 0) {
          ForEach(model.candidates) { item in
            BlitzRowDivider(leading: 0)
            row((item: item, isLocked: locked))
          }
        }
      }
      if !model.notes.isEmpty {
        DisclosureGroup("Kept or skipped · \(model.notes.count)", isExpanded: $showsNotes) {
          ForEach(Array(model.notes.enumerated()), id: \.offset) { note in
            Text(note.element).frame(maxWidth: .infinity, alignment: .leading)
          }
        }.font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).padding(12)
      }
    }
    .task { if model.scannedAt == nil { model.scan() } }
    .onChange(of: model.isBusy) { if model.isBusy { review = [] } }
  }

  private func row(_ input: (item: CacheCandidate, isLocked: Bool)) -> some View {
    let item = input.item
    return HStack(spacing: 12) {
      Toggle(
        "Select \(item.displayName)",
        isOn: Binding(
          get: { model.selected.contains(item.path) },
          set: {
            if $0 { model.selected.insert(item.path) } else { model.selected.remove(item.path) }
          })
      ).toggleStyle(BlitzCheckboxStyle(showsLabel: false)).disabled(input.isLocked)
      ApplicationIcon(source: .file(item.path), size: 28, fallback: "folder")
      VStack(alignment: .leading, spacing: 3) {
        Text(item.displayName).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
        Text("\(item.rule.title) · unchanged for \(item.rule.kind.minimumAgeDays)+ days")
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }.frame(maxWidth: .infinity, alignment: .leading).help(item.rule.recipe + "\n" + item.path)
      BlitzTrailingValue(value: ByteText.full(item.tree.bytes), detail: nil)
      Button("Show in Finder") { Finder.reveal(item.path) }.blitzButton(.quiet)
        .controlSize(.small)
    }.blitzRow()
  }
}
