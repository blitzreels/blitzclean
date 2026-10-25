import Darwin
import Foundation

/// Who started a process and why it exists, read from its executable path and parent chain.
struct ProcessOrigin: Equatable, Sendable {
  /// The tool that ships this executable, such as Remotion or Playwright.
  let tool: String?
  /// The project folder the executable or its launcher belongs to.
  let project: String?
  /// The nearest ancestor with a different program, such as `node`.
  let launcher: String?
  /// The launcher already exited, so nothing will close this process.
  let orphaned: Bool
  let startedAt: Date?
  /// Program names from the process up to its first unrelated ancestor.
  let chain: [String]

  var summary: String {
    var parts: [String] = []
    if let tool { parts.append(tool) }
    if let project { parts.append("project \(project)") }
    if orphaned {
      parts.append("its launcher already exited, safe to quit")
    } else if let launcher {
      parts.append("started by \(launcher)")
    }
    if let startedAt { parts.append("up \(MemoryControlView.uptime(since: startedAt))") }
    return parts.joined(separator: " · ")
  }

  struct ToolMatch: Equatable {
    let tool: String
    let project: String?
  }

  /// Names the tool from where its executable lives, such as `<project>/node_modules/.remotion/...`.
  static func tool(executable: String) -> ToolMatch? {
    let rules: [(marker: String, tool: String)] = [
      ("/.remotion/", "Remotion render browser"),
      ("/ms-playwright/", "Playwright test browser"),
      ("/puppeteer/", "Puppeteer browser"),
      ("/.cache/puppeteer", "Puppeteer browser"),
      ("/electron/dist/", "Electron app runtime"),
    ]
    guard let rule = rules.first(where: { executable.contains($0.marker) }) else { return nil }
    let project: String? =
      executable.range(of: "/node_modules/").map { range in
        URL(fileURLWithPath: String(executable[..<range.lowerBound])).lastPathComponent
      }
    return .init(tool: rule.tool, project: project)
  }

  static func read(_ processID: Int32) -> Self? {
    guard let info = bsdInfo(processID), let executable = path(processID) else { return nil }
    let name = PathName.last(executable)
    var chain = [name]
    var parent = Int32(info.pbi_ppid)
    var launcher: String?
    var launcherPath: String?
    for _ in 0..<8 {
      guard parent > 1, let parentPath = path(parent), let parentInfo = bsdInfo(parent) else {
        break
      }
      let parentName = PathName.last(parentPath)
      chain.append(parentName)
      if parentName != name {
        launcher = parentName
        launcherPath = parentPath
        break
      }
      parent = Int32(parentInfo.pbi_ppid)
    }
    let match = tool(executable: executable)
    let directory =
      launcherPath.flatMap { _ in ProcessWorkingDirectory.read(parent) }
      ?? ProcessWorkingDirectory.read(processID)
    let project =
      match?.project
      ?? directory.flatMap { path in
        path == "/" || path == NSHomeDirectory()
          ? nil : PathName.last(path)
      }
    return .init(
      tool: match?.tool ?? known[name], project: project, launcher: launcher,
      orphaned: launcher == nil && info.pbi_ppid <= 1 && (match != nil || known[name] != nil),
      startedAt: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)), chain: chain)
  }

  private static let known: [String: String] = [
    "chrome-headless-shell": "Headless Chrome for rendering or automation",
    "Google Chrome for Testing": "Chrome for automated tests",
    "Chromium": "Chromium browser",
  ]

  private static func bsdInfo(_ processID: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    return read == size ? info : nil
  }

  private static func path(_ processID: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
