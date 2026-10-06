import Darwin
import Foundation
import SQLite3

struct AIThreadNamesInput {
  let threads: [AIThread]
  let records: [RawProcessRecord]
  let startTimes: [Int32: TimeInterval]
  let home: URL
}

enum AIThreadNames {
  struct SessionArgument {
    let tool: AITool
    let arguments: [String]
  }

  struct ReadRequest {
    let url: URL
    let limit: Int
    let tail: Bool
  }

  static func sessionID(_ input: SessionArgument) -> String? {
    let tokens = input.arguments
    let flags: Set<String> =
      input.tool == .codexCLI
      ? ["resume", "--resume", "--session-id"] : ["--resume", "--session-id", "--session"]
    for (index, token) in tokens.enumerated() {
      if token == "--" { break }
      if token == "resume", index != 1 && !(index == 2 && tokens[1] == "exec") { continue }
      if flags.contains(token), index + 1 < tokens.count,
        let id = UUID(uuidString: tokens[index + 1])
      {
        return id.uuidString.lowercased()
      }
      let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
      if pair.count == 2, flags.contains(pair[0]), let id = UUID(uuidString: pair[1]) {
        return id.uuidString.lowercased()
      }
    }
    return nil
  }

  static func cleanTitle(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let title = value.components(separatedBy: .controlCharacters)
      .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : String(title.prefix(160))
  }

  static func enrich(_ input: AIThreadNamesInput) -> [AIThread] {
    let records = Dictionary(
      input.records.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
    let codexTitles =
      input.threads.contains { $0.tool == .codexCLI }
      ? codexIndex(input.home.appendingPathComponent(".codex/session_index.jsonl")) : [:]
    let opened = openCodexSessions(input.threads)
    return input.threads.map { original in
      var thread = original
      guard let root = thread.processIDs.first, records[root] != nil else { return thread }
      var session: String?
      if [.claudeCode, .codexCLI, .cursorAgent].contains(thread.tool) {
        session = sessionID(.init(tool: thread.tool, arguments: processArguments(root)))
      }
      switch thread.tool {
      case .claudeCode:
        let url = input.home.appendingPathComponent(".claude/sessions/\(root).json")
        if let metadata = object(.init(url: url, limit: 64 * 1_024, tail: false)),
          let pid = metadata["pid"] as? Int, pid == root,
          let started = input.startTimes[root],
          registryMatches(.init(metadata: metadata, startedAt: started))
        {
          session = (metadata["sessionId"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
            .lowercased()
          thread.sessionTitle = cleanTitle(metadata["name"])
        }
        if thread.sessionTitle == nil, let session, let directory = thread.directory {
          let project = directory.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
          let url = input.home.appendingPathComponent(
            ".claude/projects/\(project)/sessions-index.json")
          if let index = object(.init(url: url, limit: 2 * 1_024 * 1_024, tail: false)),
            let entries = index["entries"] as? [[String: Any]],
            let entry = entries.first(where: {
              ($0["sessionId"] as? String)?.lowercased() == session
            })
          {
            thread.sessionTitle = cleanTitle(entry["customTitle"]) ?? cleanTitle(entry["summary"])
          }
        }
      case .codexCLI:
        session = session ?? opened[root]
        thread.sessionTitle = session.flatMap { codexTitles[$0] }
      case .cursorAgent:
        if let session {
          thread.sessionTitle = cursorTitle(.init(home: input.home, sessionID: session))
        }
      case .codexDesktop, .otherAgent:
        break
      }
      thread.sessionID = session
      return thread
    }
  }

  static func processArguments(_ processID: Int32) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
    var size = 1_024 * 1_024
    var data = Data(count: size)
    let result = data.withUnsafeMutableBytes { buffer in
      sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0)
    }
    guard result == 0, size > MemoryLayout<Int32>.size else { return [] }
    return arguments(Data(data.prefix(size)))
  }

  static func arguments(_ data: Data) -> [String] {
    guard data.count >= MemoryLayout<Int32>.size else { return [] }
    let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard count > 0, count <= 4096 else { return [] }
    let bytes = [UInt8](data)
    var offset = MemoryLayout<Int32>.size
    while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
    while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
    var result: [String] = []
    for _ in 0..<count {
      guard offset < bytes.count else { return [] }
      let start = offset
      while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
      guard offset < bytes.count else { return [] }
      result.append(String(decoding: bytes[start..<offset], as: UTF8.self))
      offset += 1
    }
    return result
  }

  struct RegistryMatch {
    let metadata: [String: Any]
    let startedAt: TimeInterval
  }

  static func registryMatches(_ input: RegistryMatch) -> Bool {
    if let text = input.metadata["procStart"] as? String {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
      if let date = formatter.date(from: text) {
        return abs(date.timeIntervalSince1970 - input.startedAt) < 2
      }
    }
    guard let milliseconds = input.metadata["startedAt"] as? Double else { return false }
    return abs(milliseconds / 1_000 - input.startedAt) < 5
  }

  static func read(_ request: ReadRequest) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: request.url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), request.tail || size <= request.limit else {
      return nil
    }
    let offset = request.tail && size > request.limit ? size - UInt64(request.limit) : 0
    guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
    return try? handle.read(upToCount: request.limit)
  }

  static func object(_ request: ReadRequest) -> [String: Any]? {
    read(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
  }

  static func codexIndex(_ url: URL) -> [String: String] {
    guard let data = read(.init(url: url, limit: 2 * 1_024 * 1_024, tail: true)) else { return [:] }
    var titles: [String: String] = [:]
    for line in data.split(separator: 10) {
      guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let id = row["id"] as? String, let title = cleanTitle(row["thread_name"])
      else { continue }
      titles[id.lowercased()] = title
    }
    return titles
  }

  private static func openCodexSessions(_ threads: [AIThread]) -> [Int32: String] {
    let roots = threads.filter { $0.tool == .codexCLI }.compactMap { $0.processIDs.first }.prefix(
      32)
    guard !roots.isEmpty else { return [:] }
    let result = DeveloperCommand.run(
      .init(
        executable: "/usr/sbin/lsof",
        arguments: ["-p", roots.map(String.init).joined(separator: ","), "-Fpn"],
        timeout: 1, maximumBytes: 512 * 1_024))
    var current: Int32?
    var sessions: [Int32: Set<String>] = [:]
    for line in result.output.split(separator: "\n") {
      if line.first == "p" { current = Int32(line.dropFirst()) }
      guard line.first == "n", let current, line.contains("/sessions/"),
        line.contains("/rollout-"), line.hasSuffix(".jsonl")
      else { continue }
      let suffix = String(line.dropLast(6).suffix(36))
      if let id = UUID(uuidString: suffix) {
        sessions[current, default: []].insert(id.uuidString.lowercased())
      }
    }
    return sessions.compactMapValues { $0.count == 1 ? $0.first : nil }
  }

  struct CursorRequest {
    let home: URL
    let sessionID: String
  }

  static func cursorTitle(_ request: CursorRequest) -> String? {
    let root = request.home.appendingPathComponent(".cursor/chats")
    guard
      let workspaces = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    else { return nil }
    for workspace in workspaces.prefix(256) {
      let file = workspace.appendingPathComponent("\(request.sessionID)/store.db")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      var database: OpaquePointer?
      guard
        sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
          == SQLITE_OK
      else {
        sqlite3_close(database)
        continue
      }
      defer { sqlite3_close(database) }
      sqlite3_busy_timeout(database, 25)
      var statement: OpaquePointer?
      let query = "SELECT value FROM meta WHERE key = '0' AND length(value) <= 65536 LIMIT 1"
      guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { continue }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
      else { continue }
      let value = String(cString: text)
      let bytes = Array(value.utf8)
      var decoded = Data()
      if bytes.count.isMultiple(of: 2) {
        for index in stride(from: 0, to: bytes.count, by: 2) {
          guard
            let byte = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16)
          else {
            decoded.removeAll()
            break
          }
          decoded.append(byte)
        }
      }
      let data = decoded.isEmpty ? Data(value.utf8) : decoded
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        (object["agentId"] as? String)?.lowercased() == request.sessionID.lowercased()
      else { continue }
      return cleanTitle(object["name"])
    }
    return nil
  }
}
