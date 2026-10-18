import Foundation

@MainActor
final class LargeFilesModel: ObservableObject {
  @Published private(set) var items: [LargeFileItem] = []
  @Published private(set) var limited = false
  @Published private(set) var isScanning = false
  @Published private(set) var scannedAt: Date?
  @Published private(set) var moving: Set<String> = []
  @Published private(set) var message: String?
  @Published private(set) var canUndo = false
  @Published var filter = LargeFileKind.all

  private let request: LargeFileScanRequest
  private var scanGeneration = UUID()
  private var lastMoved: [TrashedItem] = []

  init(request: LargeFileScanRequest = .standard) {
    self.request = request
  }

  var visibleItems: [LargeFileItem] {
    filter == .all ? items : items.filter { $0.kind == filter }
  }

  var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

  func count(_ kind: LargeFileKind) -> Int {
    kind == .all ? items.count : items.filter { $0.kind == kind }.count
  }

  func scanIfNeeded() {
    if let scannedAt, Date.now.timeIntervalSince(scannedAt) < 300 { return }
    scan()
  }

  func scan() {
    guard moving.isEmpty else { return }
    let generation = UUID()
    scanGeneration = generation
    isScanning = true
    let request = request
    Task {
      let result = await Task.detached(priority: .utility) { LargeFileScanner.scan(request) }.value
      guard scanGeneration == generation else { return }
      items = result.items.filter { FileIdentity.read($0.path) != nil && !moving.contains($0.path) }
      limited = result.limited
      scannedAt = .now
      isScanning = false
    }
  }

  func waitForScan() async {
    while isScanning { try? await Task.sleep(for: .milliseconds(100)) }
  }

  func trash(_ item: LargeFileItem, history: CleanupOverviewModel) {
    guard !moving.contains(item.path) else { return }
    moving.insert(item.path)
    message = nil
    Task {
      do {
        let identity = item.identity
        let moved = try await Task.detached(priority: .utility) {
          try PersonalTrash.move(.init(identity: identity, recheck: {}))
        }.value
        items.removeAll { $0.path == item.path }
        lastMoved = [moved]
        canUndo = true
        let volume = CleanupVolume.read(FileManager.default.homeDirectoryForCurrentUser.path)
        history.record(
          CleanupWin(
            id: UUID().uuidString, date: .now, title: "Moved \(item.name) to the Trash",
            paths: [item.path], before: volume, after: volume, bytes: item.bytes))
        message = "Moved \(item.name) · \(ByteText.full(item.bytes)) to the Trash."
      } catch {
        message = "\(item.name) stayed. \(error.localizedDescription)"
      }
      moving.remove(item.path)
    }
  }

  func undo() {
    guard canUndo else { return }
    let restored = PersonalTrash.restore(lastMoved)
    message =
      restored == lastMoved.count
      ? "Put back." : "Could not put it back; something now uses that name. Check the Trash."
    lastMoved = []
    canUndo = false
    scan()
  }
}
