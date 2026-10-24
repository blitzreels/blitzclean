import SwiftUI

/// The main drive at a glance: one bar, then each group with the few units that hold its space.
struct DriveBreakdownView: View {
  @ObservedObject var model: DriveBreakdownModel
  let worktrees: DeveloperBrowserModel
  let history: CleanupOverviewModel
  let onBrowse: (String) -> Void
  let onCleanup: (StorageCleanupRoute) -> Void
  @State private var pending: [DriveUnit] = []
  @State private var pendingAction: PendingProcessAction?
  @State private var focus: DriveGroup?
  @State private var expanded: Set<DriveGroup> = []

  private struct Band: Identifiable {
    let group: DriveGroup
    let bytes: UInt64
    let units: [DriveUnit]
    var id: DriveGroup { group }
  }

  /// Groups and rows in the order of the last complete scan; sizes update in place without reshuffling.
  private var bands: [Band] {
    guard let breakdown = model.breakdown else { return [] }
    let rank = model.rank
    let last = Int.max
    return DriveGroup.allCases.compactMap { group in
      let units = breakdown.units
        .filter { $0.group == group && ($0.bytes >= 1_000_000 || rank[$0.id] != nil) }
        .sorted { (rank[$0.id] ?? last, $1.bytes) < (rank[$1.id] ?? last, $0.bytes) }
      let bytes = units.reduce(0) { $0 + $1.bytes }
      return units.isEmpty ? nil : Band(group: group, bytes: bytes, units: units)
    }.sorted { left, right in
      if (left.group == .system) != (right.group == .system) { return right.group == .system }
      return (rank["group:" + left.group.rawValue] ?? last, right.bytes)
        < (rank["group:" + right.group.rawValue] ?? last, left.bytes)
    }
  }

  var body: some View {
    let bands = bands
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          summary(bands)
          DriveWorktreesSection(
            model: worktrees, history: history, onConfirm: { pendingAction = $0 })
          ForEach(bands) { band in section(band).id(band.group) }
        }.padding(BlitzUI.pagePadding)
      }
      .onChange(of: focus) {
        guard let focus else { return }
        expanded.insert(focus)
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(focus, anchor: .top) }
        self.focus = nil
      }
    }
    .task { model.scanIfNeeded() }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !pending.isEmpty {
        let review = DriveConfirmation(pending)
        BlitzConfirmation(
          title: review.title, message: review.message, confirmTitle: review.confirmTitle,
          onConfirm: {
            model.remove(pending)
            pending = []
          }, onCancel: { pending = [] })
      } else if let action = pendingAction {
        BlitzConfirmation(
          title: action.title, message: action.message, confirmTitle: action.confirmTitle,
          onConfirm: {
            pendingAction = nil
            action.perform()
          }, onCancel: { pendingAction = nil })
      } else if model.busyID != nil || model.message != nil {
        HStack(spacing: 8) {
          if model.busyID != nil {
            ProgressView().controlSize(.small)
            Text("Deleting…").font(BlitzType.body).foregroundStyle(BlitzUI.supportingText)
          } else if let message = model.message {
            BlitzStatusLine(text: message.text, tone: message.tone)
          }
          Spacer()
        }.padding(.horizontal, BlitzUI.pagePadding).padding(.vertical, 12)
          .background(BlitzUI.panelBackground)
          .overlay(alignment: .top) { Rectangle().fill(BlitzUI.separator).frame(height: 1) }
      }
    }
  }

  private func summary(_ bands: [Band]) -> some View {
    let capacity = model.breakdown?.capacity
    return VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 10) {
        BlitzIconTile(symbol: "internaldrive.fill", tone: .muted, size: 36)
        Text("Macintosh HD").font(BlitzType.title)
        if let capacity {
          Text("\(ByteText.full(capacity.available)) free of \(ByteText.compact(capacity.total))")
            .font(BlitzType.callout).foregroundStyle(BlitzUI.supportingText).monospacedDigit()
          if capacity.purgeable > 1_000_000_000 {
            Text("· \(ByteText.compact(capacity.purgeable)) more macOS can free on its own")
              .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
              .help(
                "Purgeable space: iCloud copies, snapshots and caches macOS removes when needed.")
          }
        }
        Spacer()
        Group {
          if model.isScanning {
            Button("Stop") { model.cancelScan() }.blitzButton(.quiet)
          } else {
            Button("Scan again") { model.scan() }.blitzButton(.secondary)
              .disabled(model.busyID != nil)
          }
        }.controlSize(.small).frame(width: 96, alignment: .trailing)
      }
      if let capacity {
        DriveBar(
          bands: bands.map { ($0.group, $0.bytes) }, total: capacity.total,
          onSelect: { focus = $0 })
      }
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 210), spacing: 8, alignment: .leading)],
        alignment: .leading, spacing: 6
      ) {
        ForEach(bands) { band in
          Button {
            focus = band.group
          } label: {
            HStack(spacing: 6) {
              RoundedRectangle(cornerRadius: 2).fill(band.group.color).frame(width: 8, height: 8)
              Text(band.group.title).lineLimit(1).foregroundStyle(BlitzUI.primaryText)
              Text(ByteText.compact(band.bytes)).monospacedDigit()
                .foregroundStyle(BlitzUI.secondaryText)
            }.font(BlitzType.caption).contentShape(Rectangle())
          }.buttonStyle(.plain).blitzPointingHand().help("Show what is in \(band.group.title)")
        }
      }
      if model.isScanning {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Measuring the whole drive · \(model.visited.formatted()) files checked")
        }.font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).monospacedDigit()
      } else if let date = model.breakdown?.scannedAt {
        Text("Measured \(date.formatted(.relative(presentation: .named)))")
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      } else {
        Text("Measuring the whole drive…").font(BlitzType.caption)
          .foregroundStyle(BlitzUI.secondaryText)
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).blitzTable()
  }

  private func section(_ band: Band) -> some View {
    let isExpanded = expanded.contains(band.group)
    let shown = isExpanded ? band.units : Array(band.units.prefix(5))
    let deletable = band.units.filter { $0.removal == .deleteContents }
    return VStack(spacing: 0) {
      HStack(spacing: 12) {
        BlitzIconTile(symbol: band.group.symbol, tone: .muted, size: 28)
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
              Circle().fill(band.group.color).frame(width: 7, height: 7).accessibilityHidden(true)
              Text(band.group.title).font(.system(size: 14, weight: .semibold))
            }
            Text(band.group.detail).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
              .lineLimit(1)
          }
          Spacer()
          Text(ByteText.full(band.bytes)).font(BlitzType.rowTitle).monospacedDigit()
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        if band.group == .caches, deletable.count > 1 {
          Button("Delete all") { pending = deletable }.blitzButton(.accent).controlSize(.small)
            .disabled(model.busyID != nil || model.isScanning)
        }
      }.padding(16).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
      BlitzRowDivider(leading: 0)
      ForEach(shown) { unit in
        row(unit)
        if unit.id != shown.last?.id { BlitzRowDivider(leading: 54) }
      }
      if band.units.count > 5 {
        BlitzRowDivider(leading: 0)
        BlitzShowAllButton(
          total: band.units.count, noun: "items",
          isExpanded: Binding(
            get: { expanded.contains(band.group) },
            set: { if $0 { expanded.insert(band.group) } else { expanded.remove(band.group) } })
        ).padding(.vertical, 8)
      }
    }.blitzTable()
  }

  /// Opens what a row stands for: its folder in Browse, where files can be seen and deleted.
  private func open(_ unit: DriveUnit) {
    switch unit.removal {
    case .projects: onCleanup(.init(focus: .projects, path: nil))
    case .docker: onCleanup(.init(focus: .docker, path: nil))
    case .none: break
    default:
      guard let path = unit.paths.first(where: { DirectoryCheck.isDirectory($0) }) else {
        if let path = unit.paths.first { Finder.reveal(path) }
        return
      }
      onBrowse(path)
    }
  }

  private func row(_ unit: DriveUnit) -> some View {
    HStack(spacing: 12) {
      Button {
        open(unit)
      } label: {
        HStack(spacing: 12) {
          if let path = unit.paths.first {
            ApplicationIcon(source: .storage(path), size: 26, fallback: unit.group.symbol)
          } else {
            Image(systemName: unit.group.symbol).frame(width: 26)
              .foregroundStyle(BlitzUI.secondaryText)
          }
          VStack(alignment: .leading, spacing: 3) {
            Text(unit.title).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
              .foregroundStyle(BlitzUI.primaryText)
            Text(caption(unit)).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
              .lineLimit(2)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).blitzPointingHand().disabled(unit.removal == .none)
        .help(unit.removal == .none ? "" : "Open to see the files inside and delete them")
      if model.busyID == unit.id { ProgressView().controlSize(.small) }
      Text((unit.partial ? "≥ " : "") + ByteText.full(unit.bytes))
        .font(BlitzType.numeric).monospacedDigit().foregroundStyle(BlitzUI.supportingText)
        .frame(minWidth: 84, alignment: .trailing)
        .help(unit.partial ? "Some folders need Full Disk Access to be measured." : "")
      primary(unit).frame(minWidth: 112, alignment: .trailing)
      if !unit.paths.isEmpty {
        BlitzActionMenu(label: "Actions for \(unit.title)") {
          Button("Show in Finder") { Finder.reveal(unit.paths[0]) }
          if unit.removal != .browse, DirectoryCheck.isDirectory(unit.paths[0]) {
            Button("Browse folder") { onBrowse(unit.paths[0]) }
          }
        }
      } else {
        Color.clear.frame(width: 34, height: 1)
      }
    }.blitzRow()
  }

  private func caption(_ unit: DriveUnit) -> String {
    switch unit.id {
    case DriveCatalog.dependencies, DriveCatalog.builds:
      "\(unit.folders.formatted()) folders · " + unit.detail
    default: unit.detail
    }
  }

  @ViewBuilder private func primary(_ unit: DriveUnit) -> some View {
    let busy = model.busyID != nil || model.isScanning || unit.bytes < 1_000_000
    switch unit.removal {
    case .deleteContents, .deleteFolder:
      Button("Delete") { pending = [unit] }.blitzButton(.secondary).controlSize(.small)
        .disabled(busy)
    case .emptyTrash:
      Button("Empty Trash") { pending = [unit] }.blitzButton(.accent).controlSize(.small)
        .disabled(busy)
    case .simulators:
      Button("Delete devices") { pending = [unit] }.blitzButton(.secondary).controlSize(.small)
        .disabled(busy)
    case .simulatorRuntime:
      Button("Delete") { pending = [unit] }.blitzButton(.secondary).controlSize(.small)
        .disabled(busy)
    case .uninstall:
      Button("Move to Trash") { pending = [unit] }.blitzButton(.secondary).controlSize(.small)
        .disabled(busy)
    case .projects:
      Button("Review") { onCleanup(.init(focus: .projects, path: nil)) }
        .blitzButton(.secondary).controlSize(.small)
    case .docker:
      Button("Review") { onCleanup(.init(focus: .docker, path: nil)) }
        .blitzButton(.secondary).controlSize(.small)
    case .browse:
      Button("Browse") { onBrowse(unit.paths.first ?? NSHomeDirectory()) }
        .blitzButton(.quiet).controlSize(.small)
    case .reveal, .none:
      EmptyView()
    }
  }
}

/// The inline review text for one or more removals, stating exactly what goes and what stays.
struct DriveConfirmation {
  let title: String
  let message: String
  let confirmTitle: String

  init(_ units: [DriveUnit]) {
    let bytes = units.reduce(0) { $0 + $1.bytes }
    let size = ByteText.full(bytes)
    guard units.count == 1, let unit = units.first else {
      let list = units.map { "\($0.title) · \(ByteText.full($0.bytes))" }.joined(separator: "\n")
      if units.allSatisfy({ $0.removal == .deleteContents }) {
        title = "Delete \(units.count) caches?"
        message =
          list
          + "\n\nUp to \(size) is permanently deleted. Apps and tools rebuild these when needed. "
          + "Items an app has open or used recently are kept."
      } else {
        title = "Delete \(units.count) items?"
        message =
          list + "\n\nUp to \(size) is permanently deleted. "
          + "Versions Xcode no longer lists need free space about their own size to be removed."
      }
      confirmTitle = "Delete \(size)"
      return
    }
    let paths = unit.paths.joined(separator: "\n")
    switch unit.removal {
    case .emptyTrash:
      title = "Empty the Trash?"
      message = "\(size) is permanently deleted. This cannot be undone."
      confirmTitle = "Empty Trash"
    case .simulators:
      title = "Delete simulator devices?"
      message =
        "Every simulated device is deleted with the apps and data installed on it (up to \(size)). "
        + "Running simulators are shut down first. Xcode creates new devices when you need them, "
        + "and iOS versions stay installed."
      confirmTitle = "Delete devices"
    case .simulatorRuntime:
      title = "Delete \(unit.title)?"
      message =
        "\(size) is permanently deleted, with the simulated devices that use this version. "
        + "Running ones are shut down first. Xcode downloads it again if you need it. "
        + "Versions Xcode no longer lists need free space about their own size to be removed."
      confirmTitle = "Delete \(size)"
    case .uninstall:
      title = "Move \(unit.title) to Trash?"
      message =
        "\(paths)\n\nThe app goes to the Trash; empty it to free \(size). Its settings stay in App data."
      confirmTitle = "Move to Trash"
    case .deleteFolder:
      title = "Delete leftover app data?"
      message =
        "\(paths)\n\nThe app that created this is no longer installed. \(size) is permanently deleted."
      confirmTitle = "Delete \(size)"
    default:
      let age =
        unit.minimumAge >= 86_400
        ? " or used in the last day"
        : unit.minimumAge >= 6 * 3_600
          ? " or used in the last 6 hours" : unit.minimumAge > 0 ? " or used in the last hour" : ""
      title = "Delete \(unit.title)?"
      message =
        "\(paths)\n\nUp to \(size) is permanently deleted. \(unit.detail). Items an app has open\(age) are kept."
      confirmTitle = "Delete \(size)"
    }
  }
}

private struct DriveBar: View {
  let bands: [(group: DriveGroup, bytes: UInt64)]
  let total: UInt64
  let onSelect: (DriveGroup) -> Void
  @State private var hovered: DriveGroup?

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 1) {
        ForEach(bands, id: \.group) { band in
          Rectangle().fill(band.group.color)
            .opacity(hovered == nil || hovered == band.group ? 1 : 0.45)
            .frame(width: max(2, geometry.size.width * fraction(band.bytes)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? band.group : (hovered == band.group ? nil : hovered) }
            .onTapGesture { onSelect(band.group) }
            .help("\(band.group.title) · \(ByteText.full(band.bytes)) · click to see it")
        }
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: hovered)
    }.frame(height: 14).blitzPointingHand()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        bands.map { "\($0.group.title) \(ByteText.compact($0.bytes))" }.joined(separator: ", "))
  }

  private func fraction(_ bytes: UInt64) -> Double {
    total == 0 ? 0 : min(1, Double(bytes) / Double(total))
  }
}

extension DriveGroup {
  /// The group's share of the drive bar. Muted hues of similar lightness, so the bar reads as one chart
  /// and no group looks like an alert; Trash and system data stay gray.
  var color: Color {
    switch self {
    case .personal: Color(red: 0.42, green: 0.60, blue: 0.94)
    case .home: Color(red: 0.56, green: 0.52, blue: 0.90)
    case .caches: Color(red: 0.42, green: 0.76, blue: 0.68)
    case .simulators: Color(red: 0.40, green: 0.70, blue: 0.84)
    case .ai: Color(red: 0.84, green: 0.62, blue: 0.46)
    case .containers: Color(red: 0.66, green: 0.56, blue: 0.84)
    case .apps: Color(red: 0.80, green: 0.72, blue: 0.50)
    case .messages: Color(red: 0.78, green: 0.56, blue: 0.66)
    case .appData: Color(white: 0.56)
    case .trash: Color(white: 0.42)
    case .system: Color(white: 0.28)
    }
  }
}

/// Remembers whether a storage path is a folder, so rows avoid a file-system call per render.
@MainActor
enum DirectoryCheck {
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
