import Foundation

struct OldFilesResult: Equatable {
  let movedCount: Int
  let movedBytes: UInt64
  let failures: [String]
  let date: Date
}

@MainActor
final class OldFilesModel: ObservableObject {
  static let ageKey = "oldFiles.ageMonths"
  static let keptKey = "oldFiles.kept"

  @Published private(set) var items: [OldFileItem] = []
  @Published private(set) var unmeasured = 0
  @Published private(set) var isScanning = false
  @Published private(set) var scannedAt: Date?
  @Published private(set) var isTrashing = false
  @Published private(set) var completed = 0
  @Published private(set) var total = 0
  @Published private(set) var result: OldFilesResult?
  @Published private(set) var restoreMessage: String?
  @Published private(set) var kept: Set<String>
  @Published var age: OldFileAge {
    didSet {
      guard age != oldValue else { return }
      defaults.set(age.rawValue, forKey: Self.ageKey)
      scan()
    }
  }

  private let defaults: UserDefaults
  private let makeRequest: @Sendable (Date) -> OldFileScanRequest
  private var scanGeneration = UUID()
  private var lastMoved: [TrashedItem] = []

  struct Configuration {
    let defaults: UserDefaults
    let request: @Sendable (Date) -> OldFileScanRequest

    static var application: Self {
      .init(defaults: .standard, request: { OldFileScanRequest.standard(cutoff: $0) })
    }
  }

  init(_ configuration: Configuration = .application) {
    defaults = configuration.defaults
    makeRequest = configuration.request
    age = OldFileAge(rawValue: configuration.defaults.integer(forKey: Self.ageKey)) ?? .sixMonths
    kept = Set(configuration.defaults.stringArray(forKey: Self.keptKey) ?? [])
  }

  var visibleItems: [OldFileItem] { items.filter { !kept.contains($0.path) } }
  var totalBytes: UInt64 { visibleItems.reduce(0) { $0 + $1.bytes } }
  var keptCount: Int { items.count - visibleItems.count }
  var canUndo: Bool { !lastMoved.isEmpty && !isTrashing }

  func scanIfNeeded() {
    if let scannedAt, Date.now.timeIntervalSince(scannedAt) < 300 { return }
    scan()
  }

  func scan() {
    guard !isTrashing else { return }
    let generation = UUID()
    scanGeneration = generation
    isScanning = true
    let request = makeRequest(age.cutoff(from: .now))
    Task {
      let scan = await Task.detached(priority: .utility) { OldFileScanner.scan(request) }.value
      guard scanGeneration == generation else { return }
      items = scan.items
      unmeasured = scan.unmeasured
      scannedAt = .now
      isScanning = false
    }
  }

  func waitForScan() async {
    while isScanning { try? await Task.sleep(for: .milliseconds(100)) }
  }

  func keep(_ item: OldFileItem) {
    kept.insert(item.path)
    defaults.set(Array(kept).sorted(), forKey: Self.keptKey)
  }

  func showKeptAgain() {
    kept = []
    defaults.removeObject(forKey: Self.keptKey)
  }

  func trashAll(history: CleanupOverviewModel) {
    let batch = visibleItems
    guard !isTrashing, !isScanning, !batch.isEmpty else { return }
    let rules = makeRequest(age.cutoff(from: .now))
    isTrashing = true
    completed = 0
    total = batch.count
    result = nil
    restoreMessage = nil
    Task {
      var moved: [TrashedItem] = []
      var movedBytes: UInt64 = 0
      var failures: [String] = []
      for item in batch {
        do {
          let request = OldFileTrashRequest(item: item, rules: rules)
          moved.append(
            try await Task.detached(priority: .utility) {
              try OldFileTrash.trash(request)
            }.value)
          movedBytes += item.bytes
        } catch {
          failures.append("\(item.name): \(error.localizedDescription)")
        }
        completed += 1
      }
      let movedPaths = Set(moved.map(\.original))
      items.removeAll { movedPaths.contains($0.path) }
      lastMoved = moved
      if !moved.isEmpty {
        let volume = CleanupVolume.read(FileManager.default.homeDirectoryForCurrentUser.path)
        history.record(
          CleanupWin(
            id: UUID().uuidString, date: .now,
            title: "Moved \(moved.count) old \(moved.count == 1 ? "file" : "files") to the Trash",
            paths: moved.map(\.original), before: volume, after: volume, bytes: movedBytes))
      }
      result = OldFilesResult(
        movedCount: moved.count, movedBytes: movedBytes, failures: failures, date: .now)
      isTrashing = false
    }
  }

  func undo() {
    guard canUndo else { return }
    let batch = lastMoved
    lastMoved = []
    let restored = PersonalTrash.restore(batch)
    result = nil
    restoreMessage =
      restored == batch.count
      ? "Put back \(restored) \(restored == 1 ? "item" : "items")."
      : "Put back \(restored) of \(batch.count) items. Others were already moved or replaced; check the Trash."
    scan()
  }
}
