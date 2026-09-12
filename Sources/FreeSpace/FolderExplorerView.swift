import AppKit
import SwiftUI

struct FolderExplorerView: View {
  @ObservedObject var model: FolderExplorerModel
  @State private var trashCandidate: FolderEntry?

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()

      if model.entries.isEmpty && model.isScanning {
        ProgressView("Listing \(model.path)…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.entries.isEmpty {
        ContentUnavailableView(
          "Empty or unreadable",
          systemImage: "folder",
          description: Text("\(AppBrand.name) cannot list this folder.")
        )
      } else {
        list
      }
    }
    .task {
      model.loadIfNeeded()
    }
    .alert(item: $trashCandidate) { entry in
      Alert(
        title: Text("Move \(entry.name) to Trash?"),
        message: Text(
          "\(ByteText.full(entry.bytes ?? 0)) at \(entry.path). You can restore it from the Trash."),
        primaryButton: .destructive(Text("Move to Trash")) {
          model.trash(entry)
        },
        secondaryButton: .cancel()
      )
    }
  }

  private var toolbar: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Button {
          model.goUp()
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(model.path == "/")
        .help("Parent folder")

        Button("Home") {
          model.open(model.homePath)
        }
        .disabled(model.path == model.homePath)

        Spacer()

        Toggle("Hidden", isOn: $model.showsHidden)
          .toggleStyle(.checkbox)
          .font(.caption)

        Button {
          model.rescan()
        } label: {
          Label("Rescan", systemImage: "arrow.clockwise")
        }
        .disabled(model.isScanning)
      }

      HStack(spacing: 4) {
        ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
          if index > 0 {
            Image(systemName: "chevron.right")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }

          Button(crumb.title) {
            model.open(crumb.path)
          }
          .buttonStyle(.plain)
          .font(index == model.breadcrumbs.count - 1 ? .callout.weight(.semibold) : .callout)
          .foregroundStyle(index == model.breadcrumbs.count - 1 ? Color.primary : Color.secondary)
        }

        Spacer()

        Text(scanStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      if let statusMessage = model.statusMessage {
        StatusLine(message: statusMessage)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private var scanStatus: String {
    if model.isScanning {
      return "Measuring \(model.pendingCount) folders… \(ByteText.full(totalBytes)) so far"
    }

    if let scannedAt = model.scannedAt {
      return
        "\(ByteText.full(totalBytes)) · measured \(scannedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    return ByteText.full(totalBytes)
  }

  private var totalBytes: UInt64 {
    model.entries.reduce(0) { result, entry in
      result + (entry.bytes ?? 0)
    }
  }

  private var list: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(model.visibleEntries) { entry in
          FolderEntryRow(
            entry: entry,
            maxBytes: model.maxBytes,
            totalBytes: totalBytes,
            canTrash: model.canTrash(entry),
            onOpen: { selected in
              if selected.isDirectory {
                model.open(selected.path)
              } else {
                model.reveal(selected)
              }
            },
            onReveal: { selected in
              model.reveal(selected)
            },
            onTrash: { selected in
              trashCandidate = selected
            }
          )
          .padding(.horizontal, 18)
          .padding(.vertical, 5)
          Divider()
            .padding(.leading, 52)
        }
      }
      .padding(.bottom, 12)
    }
  }
}

private struct FolderEntryRow: View {
  let entry: FolderEntry
  let maxBytes: UInt64
  let totalBytes: UInt64
  let canTrash: Bool
  let onOpen: (FolderEntry) -> Void
  let onReveal: (FolderEntry) -> Void
  let onTrash: (FolderEntry) -> Void

  private var ratio: Double {
    guard let bytes = entry.bytes, maxBytes > 0 else {
      return 0
    }

    return Double(bytes) / Double(maxBytes)
  }

  private var share: String {
    guard let bytes = entry.bytes, totalBytes > 0 else {
      return ""
    }

    return PercentText.make(Double(bytes) / Double(totalBytes))
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
        .resizable()
        .scaledToFit()
        .frame(width: 22, height: 22)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(entry.name)
            .font(.callout.weight(entry.isDirectory ? .medium : .regular))
            .lineLimit(1)
            .truncationMode(.middle)
          if entry.isDirectory {
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          Spacer()
          Text(share)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }

        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(.fill.quaternary)
            Capsule()
              .fill(barColor)
              .frame(width: max(entry.bytes == nil ? 0 : 3, geometry.size.width * ratio))
          }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.3), value: ratio)
      }
      .opacity(entry.isHidden ? 0.7 : 1)

      if let bytes = entry.bytes {
        Text(ByteText.full(bytes))
          .font(.callout.weight(.semibold))
          .monospacedDigit()
          .frame(width: 92, alignment: .trailing)
      } else {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.mini)
          Text("measuring")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(width: 92, alignment: .trailing)
      }
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      onOpen(entry)
    }
    .contextMenu {
      if entry.isDirectory {
        Button("Open") {
          onOpen(entry)
        }
      }
      Button("Reveal in Finder") {
        onReveal(entry)
      }
      if canTrash {
        Divider()
        Button("Move to Trash…", role: .destructive) {
          onTrash(entry)
        }
      }
    }
  }

  private var barColor: Color {
    if ratio >= 0.6 {
      return .orange
    }

    return .accentColor
  }
}
