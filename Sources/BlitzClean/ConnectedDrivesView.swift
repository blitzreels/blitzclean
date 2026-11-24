import AppKit
import Charts
import Combine
import SwiftUI

@MainActor
final class ConnectedDrivesModel: ObservableObject {
  static let shared = ConnectedDrivesModel()

  @Published private(set) var drives: [StorageDrive] = []
  @Published private(set) var loaded = false
  private var subscriptions = Set<AnyCancellable>()
  private var loading = false
  private var pendingRefresh = false

  private init() {
    let center = NSWorkspace.shared.notificationCenter
    Publishers.MergeMany(
      [
        NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
        NSWorkspace.didRenameVolumeNotification,
      ].map { center.publisher(for: $0) }
    ).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
      .store(in: &subscriptions)
    Timer.publish(every: 60, on: .main, in: .common).autoconnect()
      .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
  }

  func refresh() {
    guard !loading else {
      pendingRefresh = true
      return
    }
    loading = true
    Task {
      repeat {
        pendingRefresh = false
        let mounted = await Task.detached(priority: .utility) {
          StorageDrives.mounted(includeAdditional: true)
        }.value
        if drives != mounted { drives = mounted }
        if !loaded { loaded = true }
      } while pendingRefresh
      loading = false
    }
  }
}

struct DriveDestination: Equatable {
  enum Action { case breakdown, browse, largestFiles }
  let drive: StorageDrive
  let action: Action
}

struct ConnectedDrivesView: View {
  @ObservedObject private var inventory = ConnectedDrivesModel.shared
  let compact: Bool
  let open: (DriveDestination) -> Void
  @AppStorage("tray.showsConnectedDrives") private var trayExpanded = false
  @State private var showsOtherVolumes = false

  private var visible: [StorageDrive] {
    showsOtherVolumes ? inventory.drives : inventory.drives.filter(\.browsable)
  }

  var body: some View {
    Group {
      if compact {
        VStack(spacing: 0) {
          Button {
            trayExpanded.toggle()
          } label: {
            HStack {
              Image(systemName: "externaldrive")
              Text("Connected drives").font(BlitzType.rowTitle)
              Spacer()
              Text(inventory.drives.count.formatted()).font(BlitzType.caption).monospacedDigit()
              Image(systemName: trayExpanded ? "chevron.up" : "chevron.down")
            }.padding(10).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityValue(trayExpanded ? "Expanded" : "Collapsed")
          if trayExpanded {
            ScrollView {
              VStack(spacing: 0) {
                emptyState
                ForEach(visible) { drive in
                  BlitzRowDivider(leading: 0)
                  compactChart(drive)
                }
                otherVolumes
              }
            }.frame(height: min(190, CGFloat(visible.count) * 63 + footerHeight))
          }
        }.blitzTable()
      } else {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Connected drives").font(BlitzType.section)
            Spacer()
            otherVolumes
          }
          emptyState
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
            ForEach(visible) { drive in
              VStack(alignment: .leading, spacing: 14) {
                HStack {
                  Label(
                    drive.name, systemImage: drive.internalDisk ? "internaldrive" : "externaldrive"
                  )
                  .font(BlitzType.headline).lineLimit(1).truncationMode(.middle).help(drive.path)
                  Spacer()
                  if drive.total > 0 {
                    Text("\(ByteText.capacity(drive.total)) total").font(BlitzType.caption)
                      .foregroundStyle(BlitzUI.secondaryText).fixedSize()
                  }
                }
                if let used = drive.usedBytes {
                  Button {
                    open(.init(drive: drive, action: .breakdown))
                  } label: {
                    HStack(spacing: 22) {
                      DriveCapacityRing(drive: drive, used: used, compact: false)
                      VStack(alignment: .leading, spacing: 10) {
                        amount((used, "Used", DriveCapacityRing.usedColor))
                        amount((drive.available, "Free", BlitzUI.mint))
                      }
                      Spacer(minLength: 0)
                      BlitzChevron()
                    }.padding(.vertical, 2).contentShape(Rectangle())
                  }.buttonStyle(.plain).blitzPointingHand()
                    .accessibilityLabel("Analyze " + drive.name)
                    .accessibilityValue(
                      ByteText.capacity(used) + " used, " + ByteText.capacity(drive.available)
                        + " free"
                    )
                    .help("See what uses space on " + drive.name)
                } else {
                  Text("Capacity unavailable").font(BlitzType.body)
                }
                BlitzRowDivider(leading: 0)
                HStack(spacing: 8) { actions(drive) }
              }.blitzCard(padding: 16)
            }
          }
        }
      }
    }.task { inventory.refresh() }
  }

  private func ring(_ input: (drive: StorageDrive, used: UInt64)) -> some View {
    Button {
      open(.init(drive: input.drive, action: .breakdown))
    } label: {
      DriveCapacityRing(drive: input.drive, used: input.used, compact: compact)
        .contentShape(Rectangle())
    }.buttonStyle(.plain).blitzPointingHand()
      .help("See what uses space on " + input.drive.name)
      .accessibilityLabel("Analyze " + input.drive.name)
      .accessibilityValue(
        (Double(input.used) / Double(input.drive.total)).formatted(.percent) + " used")
  }

  private func amount(_ input: (bytes: UInt64, title: String, color: Color)) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        Circle().fill(input.color).frame(width: 7, height: 7)
        Text(input.title).font(BlitzType.caption).foregroundStyle(BlitzUI.supportingText)
      }
      Text(ByteText.capacity(input.bytes)).font(BlitzNumberFont.value(22)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.75)
    }.accessibilityElement(children: .combine)
  }

  private func compactChart(_ drive: StorageDrive) -> some View {
    HStack(spacing: 8) {
      if let used = drive.usedBytes {
        ring((drive, used))
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(drive.name).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
        Text(
          drive.usedBytes.map {
            "\(ByteText.capacity($0)) used · \(ByteText.capacity(drive.available)) free"
          } ?? "Capacity unavailable"
        )
        .font(BlitzType.caption).foregroundStyle(BlitzUI.supportingText)
        .lineLimit(1).minimumScaleFactor(0.8)
      }.help(drive.path)
      Spacer(minLength: 0)
      actions(drive)
    }.padding(.horizontal, 9).frame(height: 62)
  }

  @ViewBuilder private func actions(_ drive: StorageDrive) -> some View {
    actionButton((drive, .browse, "Browse folders", "folder"))
    actionButton((drive, .largestFiles, "Largest files", "list.number"))
  }

  private var footerHeight: CGFloat {
    inventory.drives.contains(where: { !$0.browsable }) || visible.isEmpty ? 34 : 0
  }

  @ViewBuilder private var emptyState: some View {
    if inventory.drives.isEmpty {
      Text(inventory.loaded ? "No mounted drives found" : "Reading drives…")
        .font(BlitzType.caption).padding(8)
    }
  }

  @ViewBuilder private var otherVolumes: some View {
    let other = inventory.drives.filter { !$0.browsable }.count
    if other > 0 {
      Button(showsOtherVolumes ? "Hide other volumes" : "Show other volumes · \(other)") {
        showsOtherVolumes.toggle()
      }.blitzButton(.quiet).controlSize(.small)
    }
  }

  private func actionButton(
    _ input: (drive: StorageDrive, action: DriveDestination.Action, label: String, symbol: String)
  ) -> some View {
    Button {
      open(.init(drive: input.drive, action: input.action))
    } label: {
      if compact {
        Image(systemName: input.symbol).frame(width: 16)
      } else {
        Label(input.label, systemImage: input.symbol)
      }
    }.blitzButton(.secondary).controlSize(.small)
      .accessibilityLabel("\(input.label) on \(input.drive.name)")
      .help("\(input.label) on \(input.drive.path)")
  }
}

private struct DriveCapacityRing: View {
  let drive: StorageDrive
  let used: UInt64
  let compact: Bool

  static let usedColor = Color(red: 0.58, green: 0.64, blue: 0.97)

  var body: some View {
    let percent = (Double(used) / Double(drive.total)).formatted(
      .percent.precision(.fractionLength(0...(compact ? 0 : 1))))
    ZStack {
      Chart {
        if used > 0 {
          SectorMark(
            angle: .value("Used", Double(used)), innerRadius: .ratio(0.72),
            angularInset: drive.available == 0 ? 0 : 0.8
          )
          .cornerRadius(compact ? 1 : 2)
          .foregroundStyle(
            .linearGradient(
              colors: [Self.usedColor, Self.usedColor.opacity(0.72)],
              startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        if drive.available > 0 {
          SectorMark(
            angle: .value("Free", Double(drive.available)), innerRadius: .ratio(0.72),
            angularInset: used == 0 ? 0 : 0.8
          )
          .cornerRadius(compact ? 1 : 2).foregroundStyle(BlitzUI.mint)
        }
      }.chartLegend(.hidden).accessibilityHidden(true)
      VStack(spacing: 0) {
        Text(percent).font(BlitzNumberFont.value(compact ? 10 : 21)).monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.65)
        if !compact {
          Text("used").font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        }
      }.frame(maxWidth: compact ? 30 : 74)
    }.frame(width: compact ? 43 : 108, height: compact ? 43 : 108)
      .accessibilityElement(children: .ignore).accessibilityLabel("\(drive.name), \(percent) used")
  }
}
