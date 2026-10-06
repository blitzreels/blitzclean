import AppKit
import Darwin
import Foundation

enum MediaProcess {
  struct Request {
    let executable: String
    let arguments: [String]
    let directory: URL
    let timeout: TimeInterval
    let diskGuard: URL?
  }

  static func run(_ request: Request) throws -> Data {
    try Task.checkCancellation()
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: request.executable)
    process.arguments = request.arguments
    process.currentDirectoryURL = request.directory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let termination = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { _ in
      if process.isRunning { process.terminate() }
    }
    defer { NotificationCenter.default.removeObserver(termination) }
    let buffer = MediaProcessBuffer()
    let reader = DispatchGroup()
    reader.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { reader.leave() }
      while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
        buffer.append(chunk)
      }
    }
    let deadline = Date.now.addingTimeInterval(request.timeout)
    var stoppedAt: Date?
    var reason: String?
    while process.isRunning {
      if reason == nil {
        if Task.isCancelled {
          reason = "Export cancelled. Originals are intact."
        } else if Date.now > deadline {
          reason = "Media operation timed out. Originals are intact."
        } else if let disk = request.diskGuard, let capacity = CleanupVolume.read(disk.path),
          capacity.available < 128 * 1_024 * 1_024
        {
          reason = "Export stopped because the destination is almost full. Originals are intact."
        }
        if reason != nil {
          stoppedAt = .now
          process.terminate()
        }
      }
      if let stoppedAt, Date.now.timeIntervalSince(stoppedAt) > 2 {
        kill(process.processIdentifier, SIGKILL)
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    process.waitUntilExit()
    reader.wait()
    let output = buffer.data
    if let reason { throw MediaOperationError(message: reason) }
    guard process.terminationStatus == 0 else {
      let detail = String(decoding: output.suffix(2_048), as: UTF8.self)
      throw MediaOperationError(message: "Media operation failed. \(detail)")
    }
    return output
  }
}

private final class MediaProcessBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(data.prefix(max(0, 262_144 - storage.count)))
  }

  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
