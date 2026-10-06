import AppKit
import Foundation

@MainActor
final class MediaLibraryModel: ObservableObject {
  static let application = MediaLibraryModel()
  @Published var selected: Set<String> = []
  @Published private(set) var duplicates: [MediaDuplicateGroup] = []
  @Published private(set) var isFindingDuplicates = false
  @Published private(set) var isExporting = false
  @Published private(set) var status: String?
  @Published private(set) var exports: [MediaExportResult] = []
  private var duplicateTask: Task<MediaDuplicateResult, Never>?
  private var exportTask: Task<MediaExportResult, Error>?
  private var generation = UUID()
  private let historyURL = AppData.file("media-exports.json")

  init() {
    if let data = try? Data(contentsOf: historyURL), data.count <= 512 * 1_024,
      let saved = try? JSONDecoder().decode([MediaExportResult].self, from: data)
    {
      exports = Array(saved.prefix(100))
    }
  }

  func findDuplicates(_ files: [ReviewFile]) {
    guard !isFindingDuplicates, !isExporting else { return }
    isFindingDuplicates = true
    duplicates = []
    status = "Comparing file contents. Large recordings can take up to two minutes."
    let token = UUID()
    generation = token
    let worker = Task.detached(priority: .utility) { MediaDuplicateScanner.scan(files) }
    duplicateTask = worker
    Task {
      let result = await worker.value
      guard generation == token else { return }
      duplicates = result.groups
      isFindingDuplicates = false
      duplicateTask = nil
      status =
        "\(result.groups.count) exact duplicate groups. \(result.skipped) files skipped."
        + (result.limited ? " Comparison is partial; narrow the folder and try again." : "")
    }
  }

  func invalidateDuplicates() {
    generation = UUID()
    duplicateTask?.cancel()
    duplicateTask = nil
    isFindingDuplicates = false
    duplicates = []
  }

  func cancel() {
    if isFindingDuplicates {
      invalidateDuplicates()
      status = "Duplicate comparison cancelled."
    }
    exportTask?.cancel()
  }

  func selectExtraCopies() {
    selected = Set(duplicates.flatMap { $0.files.dropFirst().map(\.path) })
    status =
      "Extra copies selected. One file in each group remains unselected. Review before moving to Trash."
  }

  func export(_ request: MediaExportRequest) {
    guard !isExporting else { return }
    isExporting = true
    status = "Exporting and checking playback…"
    let worker = Task.detached(priority: .utility) { try MediaExportEngine.run(request) }
    exportTask = worker
    Task {
      do {
        let result = try await worker.value
        exports.insert(result, at: 0)
        exports = Array(exports.prefix(100))
        status =
          "Saved \(URL(fileURLWithPath: result.output).lastPathComponent). "
          + "\(ByteText.full(UInt64(result.inputBytes))) → \(ByteText.full(UInt64(result.outputBytes)))."
          + (result.outputBytes >= result.inputBytes ? " Output is larger than the source." : "")
        do {
          try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
          var data = try JSONEncoder().encode(exports)
          while data.count > 512 * 1_024, exports.count > 1 {
            exports.removeLast()
            data = try JSONEncoder().encode(exports)
          }
          try data.write(to: historyURL, options: .atomic)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch { status = "Export saved, but its history could not be saved. \(result.output)" }
      } catch { status = error.localizedDescription }
      isExporting = false
      exportTask = nil
    }
  }

  func reveal(_ result: MediaExportResult) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.output)])
  }
}
