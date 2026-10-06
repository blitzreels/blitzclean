import Foundation
import SwiftUI

struct SimulatorDeviceService: Sendable {
  enum Action: Sendable { case shutdown, delete }

  struct Request: Sendable {
    let device: SimulatorDeviceInfo
    let action: Action
  }

  struct Outcome: Sendable {
    let devices: [SimulatorDeviceInfo]
    let message: String
    let win: CleanupWin?
  }

  enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? {
      switch self {
      case .message(let text): text
      }
    }
  }

  let run: @Sendable (DeveloperCommand.Request) -> CleanupCommandResult

  init(
    run: @escaping @Sendable (DeveloperCommand.Request) -> CleanupCommandResult = DeveloperCommand
      .run
  ) {
    self.run = run
  }

  func list() throws -> [SimulatorDeviceInfo] {
    let result = run(
      .init(
        executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "--json"],
        timeout: 8, maximumBytes: 2 * 1_024 * 1_024))
    guard result.status == 0, let devices = Self.decode(result.output) else {
      throw Failure.message(
        "Could not read simulator devices. Check that Xcode is installed, then refresh.")
    }
    return devices
  }

  func execute(_ request: Request) throws -> Outcome {
    guard let uuid = UUID(uuidString: request.device.id) else {
      throw Failure.message("This device has no valid identifier. Refresh before trying again.")
    }
    let id = uuid.uuidString
    let devices = try list()
    guard let current = devices.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }),
      current.name == request.device.name, current.runtime == request.device.runtime
    else {
      throw Failure.message(
        "The selected device changed or was removed. Refresh before trying again.")
    }
    if request.action == .delete, current.state != "Shutdown" {
      throw Failure.message("Shut down \(current.name) before deleting its apps and data.")
    }
    if request.action == .shutdown, current.state == "Shutdown" {
      return Outcome(devices: devices, message: "\(current.name) is already shut down.", win: nil)
    }
    guard current.state == "Booted" || current.state == "Shutdown" else {
      throw Failure.message(
        "\(current.name) is changing state. Wait and refresh before trying again.")
    }
    let before = CleanupVolume.read(NSHomeDirectory())
    let command = request.action == .delete ? "delete" : "shutdown"
    let result = run(
      .init(
        executable: "/usr/bin/xcrun", arguments: ["simctl", command, id],
        timeout: 30, maximumBytes: 64 * 1_024))
    let updated = try list()
    let remaining = updated.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    if request.action == .delete, remaining == nil {
      let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(id)").path
      let win = CleanupWin(
        id: UUID().uuidString, date: .now,
        title: "Deleted simulator · \(current.name) · \(current.runtime)",
        paths: [path], before: before, after: CleanupVolume.read(NSHomeDirectory()),
        bytes: current.bytes)
      return Outcome(
        devices: updated, message: "\(current.name) deleted. The iOS runtime stays installed.",
        win: win)
    }
    if request.action == .shutdown, remaining?.state == "Shutdown" {
      return Outcome(devices: updated, message: "\(current.name) shut down.", win: nil)
    }
    throw Failure.message(
      result.status == 0
        ? "\(current.name) has not finished \(command == "delete" ? "deleting" : "shutting down"). Refresh to check its state."
        : "Could not \(command == "delete" ? "delete" : "shut down") \(current.name). Apple’s simulator service returned \(result.status). Refresh and try again."
    )
  }

  static func isDevicePath(_ path: String) -> Bool {
    let prefix = "/System/Volumes/Data"
    let visible = path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
    let root = NSHomeDirectory() + "/Library/Developer/CoreSimulator"
    return visible == root || visible == root + "/Devices" || visible.hasPrefix(root + "/Devices/")
  }

  static func decode(_ text: String) -> [SimulatorDeviceInfo]? {
    struct Device: Decodable {
      let udid: String
      let name: String
      let state: String
      let lastBootedAt: Date?
      let dataPathSize: UInt64?
    }
    struct List: Decodable { let devices: [String: [Device]] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let list = try? decoder.decode(List.self, from: Data(text.utf8)) else { return nil }
    var result: [SimulatorDeviceInfo] = []
    for (runtime, devices) in list.devices {
      let parts = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        .split(separator: "-", maxSplits: 1)
      let name = parts.map(String.init).joined(separator: " ")
        .replacingOccurrences(of: "-", with: ".")
      for device in devices {
        result.append(
          SimulatorDeviceInfo(
            id: device.udid, name: device.name,
            runtime: name, state: device.state,
            lastBootedAt: device.lastBootedAt, bytes: device.dataPathSize ?? 0))
      }
    }
    return result.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
  }
}

@MainActor
final class SimulatorDevicesModel: ObservableObject {
  @Published private(set) var devices: [SimulatorDeviceInfo] = []
  @Published private(set) var busyID: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var loaded = false
  @Published private(set) var message: String?
  private let service = SimulatorDeviceService()

  func refresh() async {
    guard !isRefreshing, busyID == nil else { return }
    isRefreshing = true
    let service = service
    let result = await Task.detached(priority: .utility) { Result { try service.list() } }.value
    switch result {
    case .success(let devices): self.devices = devices
    case .failure(let error): message = error.localizedDescription
    }
    loaded = true
    isRefreshing = false
  }

  struct PerformRequest {
    let device: SimulatorDeviceInfo
    let action: SimulatorDeviceService.Action
    let history: CleanupOverviewModel
  }

  func perform(_ request: PerformRequest) {
    guard busyID == nil, !isRefreshing else { return }
    busyID = request.device.id
    message = nil
    let service = service
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        Result { try service.execute(.init(device: request.device, action: request.action)) }
      }.value
      switch result {
      case .success(let outcome):
        devices = outcome.devices
        message = outcome.message
        if let win = outcome.win { request.history.record(win) }
      case .failure(let error): message = error.localizedDescription
      }
      busyID = nil
    }
  }
}

struct SimulatorDevicesView: View {
  @ObservedObject var model: SimulatorDevicesModel
  let history: CleanupOverviewModel
  @State private var pending: SimulatorDeviceInfo?
  @State private var showsAll = false

  private static let rowLimit = 5

  private var detail: String {
    model.devices.isEmpty
      ? "Delete a device’s apps and data"
      : "\(model.devices.count) devices · iOS runtimes stay installed"
  }

  var body: some View {
    let devices = showsAll ? model.devices : Array(model.devices.prefix(Self.rowLimit))
    BlitzStorageSection(
      title: "Simulated devices", symbol: "iphone.gen3", detail: detail,
      trailing: model.devices.isEmpty
        ? nil : ByteText.full(model.devices.reduce(0) { $0 + $1.bytes }),
      showsContent: true
    ) {
      VStack(spacing: 0) {
        if let message = model.message {
          BlitzStatusLine(text: message, tone: .working).padding(.horizontal, 16)
            .padding(.vertical, 10)
          BlitzRowDivider(leading: 0)
        }
        if model.devices.isEmpty {
          BlitzEmptyRow(
            text: model.loaded ? "No simulated devices" : "Reading simulated devices…",
            isLoading: !model.loaded)
        }
        ForEach(devices) { device in
          row(device)
          if let pending, pending.id == device.id {
            BlitzConfirmation(
              title: "Delete \(pending.name)?",
              message:
                "\(pending.runtime) · \(ByteText.full(pending.bytes)). Permanently deletes this device’s apps and data. The iOS runtime stays installed.",
              confirmTitle: "Delete device",
              onConfirm: {
                self.pending = nil
                model.perform(.init(device: pending, action: .delete, history: history))
              }, onCancel: { self.pending = nil })
          }
          if device.id != devices.last?.id { BlitzRowDivider(leading: 44) }
        }
        if model.devices.count > Self.rowLimit {
          BlitzRowDivider(leading: 0)
          BlitzShowAllButton(total: model.devices.count, noun: "devices", isExpanded: $showsAll)
            .padding(.vertical, 8)
        }
      }
    }.task { if !model.loaded { await model.refresh() } }
  }

  private func row(_ device: SimulatorDeviceInfo) -> some View {
    let disabled = model.busyID != nil || model.isRefreshing
    return HStack(spacing: 12) {
      Image(systemName: "iphone.gen3").foregroundStyle(BlitzUI.secondaryText).frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        Text(device.name).font(BlitzType.rowTitle).lineLimit(1)
        Text("\(device.runtime) · \(device.state)").font(BlitzType.caption)
          .foregroundStyle(BlitzUI.secondaryText)
      }.frame(maxWidth: .infinity, alignment: .leading).help(device.id)
      BlitzTrailingValue(value: ByteText.full(device.bytes), detail: nil)
      Group {
        if model.busyID == device.id {
          ProgressView().controlSize(.small)
        } else if device.state == "Booted" {
          Button("Shut down") {
            model.perform(.init(device: device, action: .shutdown, history: history))
          }.blitzButton(.secondary).controlSize(.small).disabled(disabled)
        } else if device.state == "Shutdown" {
          Button("Delete device…", role: .destructive) { pending = device }
            .blitzButton(.secondary).controlSize(.small).disabled(disabled)
            .accessibilityLabel("Delete device \(device.name) \(device.runtime)")
            .help("Permanently delete this simulated device.")
        }
      }.frame(width: 124, alignment: .trailing)
    }.blitzRow()
  }
}
