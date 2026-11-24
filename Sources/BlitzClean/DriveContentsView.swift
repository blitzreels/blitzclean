import QuickLookThumbnailing
import SwiftUI

struct DriveContentsView: View {
  let drive: StorageDrive
  let history: CleanupOverviewModel
  let back: () -> Void
  let browse: (String) -> Void
  @StateObject private var model = DriveContentsModel()
  @State private var tab = Tab.categories
  @State private var selected: DriveFileCategory?
  @State private var limit = 12

  private enum Tab: String, CaseIterable {
    case categories = "Categories"
    case growth = "What grew?"
    case cleanup = "Review cleanup"
  }
  private var contents: DriveContents? { model.progress?.contents ?? model.report?.contents }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Button("All drives", systemImage: "chevron.left", action: back).blitzButton(.quiet)
          Spacer()
          Button(model.scanning ? "Stop scan" : "Scan again") {
            if model.scanning {
              model.stop()
            } else {
              selected = nil
              model.scan(drive)
            }
          }.blitzButton(.secondary)
        }
        HStack(alignment: .firstTextBaseline) {
          Text(drive.name).font(BlitzType.largeTitle)
          Spacer()
          if let used = drive.usedBytes {
            Text("\(ByteText.capacity(used)) used · \(ByteText.capacity(drive.available)) free")
              .font(BlitzType.callout).foregroundStyle(BlitzUI.supportingText)
          }
        }
        BlitzSegmentedPicker(
          title: "Drive analysis", options: Tab.allCases, selection: $tab, label: { $0.rawValue }
        )
        .frame(maxWidth: 460)
        if model.scanning {
          Text("Measuring · \((model.progress?.visited ?? 0).formatted()) files checked").font(
            BlitzType.caption)
          BlitzProgressBar(fraction: nil, height: 3)
        } else if let report = model.report {
          Text(
            "Scanned \(report.reading.date.formatted(date: .abbreviated, time: .shortened)) · \(report.visited.formatted()) files"
              + (report.unreadable > 0 ? " · \(report.unreadable) unreadable locations" : "")
          )
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        }
        if let message = model.message { BlitzStatusLine(text: message, tone: .warning) }
        switch tab {
        case .categories: categories
        case .growth: growth
        case .cleanup:
          if model.scanning {
            Text("Cleanup review will be ready when the scan finishes.").font(BlitzType.body)
          } else if let report = model.report {
            DriveCleanupReviewView(
              drive: drive, report: report, history: history, browse: browse,
              refresh: { model.scan(drive) }
            )
            .id(report.reading.date)
          }
        }
      }.padding(BlitzUI.pagePadding).frame(maxWidth: .infinity, alignment: .leading)
    }.task { model.load(drive) }
      .onDisappear { model.stop() }
  }

  @ViewBuilder private var categories: some View {
    if let category = selected, let contents {
      Button("All categories", systemImage: "chevron.left") { selected = nil }.blitzButton(.quiet)
      Text("\(category.rawValue) · \(ByteText.capacity(contents.bytes[category] ?? 0))")
        .font(BlitzType.title)
      let files = contents.largest[category] ?? []
      Text("Largest files · up to \(DriveContents.fileLimit) per category").font(BlitzType.caption)
        .foregroundStyle(BlitzUI.secondaryText)
      LazyVStack(spacing: 0) {
        ForEach(files.prefix(limit)) { file in
          HStack(spacing: 12) {
            DriveFilePreview(file: file)
            VStack(alignment: .leading, spacing: 3) {
              Text(file.name).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
              Text(file.path).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
                .lineLimit(1).truncationMode(.middle).help(file.path)
            }
            Spacer()
            Text(ByteText.capacity(file.bytes)).monospacedDigit()
            Button("Show in Finder") { Finder.reveal(file.path) }.blitzButton(.quiet)
          }.blitzRow()
          BlitzRowDivider(leading: 0)
        }
        if files.count > limit { Button("Show more files") { limit += 20 }.blitzButton(.quiet) }
      }.blitzTable()
    } else if let contents {
      let sorted = contents.bytes.sorted {
        $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(sorted, id: \.key) { entry in
          Button {
            selected = entry.key
            limit = 12
          } label: {
            VStack(spacing: 7) {
              HStack {
                Text(entry.key.rawValue).font(BlitzType.rowTitle)
                Spacer()
                Text(ByteText.capacity(entry.value)).font(BlitzType.label).monospacedDigit()
                BlitzChevron()
              }
              GeometryReader { geo in
                ZStack(alignment: .leading) {
                  Capsule().fill(BlitzUI.quietFill)
                  Capsule().fill(entry.key.color.gradient)
                    .frame(
                      width: geo.size.width * CGFloat(entry.value)
                        / CGFloat(max(1, sorted.first?.value ?? 1)))
                }
              }.frame(height: 8)
            }.padding(12).contentShape(Rectangle())
          }.buttonStyle(.plain).blitzPointingHand()
            .accessibilityLabel("\(entry.key.rawValue), \(ByteText.capacity(entry.value))")
        }
        if sorted.isEmpty { Text("No allocated files found yet.").font(BlitzType.body).padding(12) }
      }.blitzTable()
      if !model.scanning, let used = drive.usedBytes {
        let measured = contents.bytes.values.reduce(0, +)
        if used > measured {
          Text(
            "\(ByteText.capacity(used - measured)) outside measured files, including filesystem overhead and unreadable locations."
          )
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        }
      }
    } else if !model.scanning {
      Text("Scan this drive to see what uses space.").font(BlitzType.body)
    }
  }

  @ViewBuilder private var growth: some View {
    if let report = model.report, let prior = report.previous {
      Text("Top-level folders since \(prior.date.formatted(date: .abbreviated, time: .shortened))")
        .font(BlitzType.section)
      let changes = report.reading.growth(since: prior)
      if changes.isEmpty {
        Text("No measured folders grew between these scans.").font(BlitzType.body)
      }
      ForEach(changes, id: \.key) { item in
        HStack {
          Label(item.key, systemImage: "folder").font(BlitzType.rowTitle)
          Spacer()
          Text("+\(ByteText.capacity(item.value))").font(BlitzType.label).monospacedDigit()
          Button("Browse") {
            browse(URL(fileURLWithPath: drive.path).appendingPathComponent(item.key).path)
          }
          .blitzButton(.secondary)
        }.blitzCard(padding: 12)
      }
      if !report.reading.incomplete.union(prior.incomplete).isEmpty {
        Text("Folders with incomplete measurements are excluded from this comparison.").font(
          BlitzType.caption)
      }
    } else {
      Text(
        model.scanning
          ? "Measuring folders for comparison…"
          : "Scan again after files change to see which folders grew."
      )
      .font(BlitzType.body)
    }
  }
}

extension DriveFileCategory {
  fileprivate var color: Color {
    switch self {
    case .recordings: .mint
    case .videos: .cyan
    case .exports: .teal
    case .photos: .pink
    case .audio: .purple
    case .applications: .blue
    case .archives: .indigo
    case .builds: .orange
    case .other: .gray
    }
  }
}

private struct DriveFilePreview: View {
  let file: ReviewFile
  @State private var thumbnail: NSImage?

  var body: some View {
    Group {
      if let thumbnail {
        Image(nsImage: thumbnail).resizable().scaledToFill()
      } else {
        Image(systemName: file.kind == "Video" ? "film" : "doc").foregroundStyle(
          BlitzUI.secondaryText)
      }
    }.frame(width: 58, height: 38).background(BlitzUI.quietFill)
      .clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
      .task(id: file) {
        thumbnail = nil
        guard ["Video", "Image"].contains(file.kind) else { return }
        let request = QLThumbnailGenerator.Request(
          fileAt: URL(fileURLWithPath: file.path),
          size: CGSize(width: 116, height: 76), scale: 1, representationTypes: .thumbnail)
        let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        if !Task.isCancelled { thumbnail = result?.nsImage }
      }
  }
}
