import AppKit
import SwiftUI

struct MediaExportSheet: View {
  struct Input {
    let files: [ReviewFile]
    let roots: [String]
    let media: MediaLibraryModel
    let onClose: () -> Void
  }

  let input: Input
  @State private var ordered: [ReviewFile]
  @State private var kind: MediaExportKind
  @State private var destination: URL?

  init(input: Input) {
    self.input = input
    _ordered = State(initialValue: input.files)
    _kind = State(
      initialValue: input.files.count > 1
        ? .join
        : input.files.first?.kind == "Video" ? .video : .losslessImage)
  }

  private var choices: [MediaExportKind] {
    ordered.count > 1
      ? [.join] : ordered.first?.kind == "Video" ? [.video] : [.losslessImage, .image]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(ordered.count > 1 ? "Join your recordings" : "Create an optimized copy")
        .font(.system(size: 23, weight: .semibold))
      BlitzSegmentedPicker(
        title: "Export", options: choices, selection: $kind,
        label: { $0.rawValue })
      Text(kind.detail).font(.system(size: 12)).foregroundStyle(.secondary)
      ScrollView {
        VStack(spacing: 0) {
          ForEach(Array(ordered.enumerated()), id: \.element.id) { index, file in
            HStack(spacing: 12) {
              Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
              Text(file.name).lineLimit(1).truncationMode(.middle)
              Spacer()
              Text(ByteText.full(file.bytes)).foregroundStyle(.secondary).monospacedDigit()
              if ordered.count > 1 {
                Button {
                  ordered.swapAt(index, index - 1)
                } label: {
                  Image(systemName: "arrow.up")
                }.disabled(index == 0).help("Move earlier")
                Button {
                  ordered.swapAt(index, index + 1)
                } label: {
                  Image(systemName: "arrow.down")
                }.disabled(index == ordered.count - 1).help("Move later")
              }
            }.font(.system(size: 12)).padding(.vertical, 10)
            Divider()
          }
        }
      }.frame(maxHeight: 200)
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text("Save new file to").font(.system(size: 12, weight: .semibold))
          Text(destination?.path ?? "Choose an output folder")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .lineLimit(2).truncationMode(.middle)
        }
        Spacer()
        Button("Choose folder…") { chooseDestination() }
      }
      Label(
        "Creates a new file and keeps the originals. Extra disk space is required.",
        systemImage: "info.circle"
      )
      .font(.system(size: 11)).foregroundStyle(.secondary)
      HStack {
        Button("Cancel") { input.onClose() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Export copy") {
          guard let destination else { return }
          input.media.export(
            .init(files: ordered, roots: input.roots, destination: destination, kind: kind))
          input.onClose()
        }.buttonStyle(BlitzButtonStyle(.accent)).keyboardShortcut(.defaultAction)
          .disabled(
            destination == nil || ordered.contains { !["Video", "Image"].contains($0.kind) }
              || (ordered.count > 1 && ordered.contains { $0.kind != "Video" }))
      }
    }.padding(BlitzUI.pagePadding).frame(
      maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func chooseDestination() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Save the new copy here. Originals stay in their current folders."
    if panel.runModal() == .OK { destination = panel.url }
  }
}
