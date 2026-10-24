import AppKit
import Darwin
import Foundation

enum DevProcessKind: String, Equatable, Sendable, CaseIterable {
  case claudeCode
  case codex
  case aiAgent
  case devServer
  case listener
  case simulator
  case shell

  var title: String {
    switch self {
    case .claudeCode:
      "Claude Code"
    case .codex:
      "Codex"
    case .aiAgent:
      "AI agent"
    case .devServer:
      "Dev server"
    case .listener:
      "Listening"
    case .simulator:
      "Simulator"
    case .shell:
      "Shell"
    }
  }

  var systemImage: String {
    switch self {
    case .claudeCode:
      "sparkles.rectangle.stack"
    case .codex:
      "terminal.fill"
    case .aiAgent:
      "brain"
    case .devServer:
      "server.rack"
    case .listener:
      "network"
    case .simulator:
      "iphone"
    case .shell:
      "apple.terminal"
    }
  }

  var group: DevProcessGroup {
    switch self {
    case .claudeCode, .codex, .aiAgent:
      .agents
    case .devServer, .listener, .simulator:
      .servers
    case .shell:
      .shells
    }
  }
}

enum DevProcessGroup: String, CaseIterable, Identifiable, Sendable {
  case agents = "AI agents"
  case servers = "Servers & ports"
  case shells = "Terminal shells"

  var id: Self {
    self
  }
}

struct DevProcess: Identifiable, Equatable, Sendable {
  let processID: Int32
  let parentProcessID: Int32
  let kind: DevProcessKind
  let name: String
  let detail: String
  let workingDirectory: String?
  let listeningPorts: [Int]
  let cpuPercent: Double
  let memoryBytes: UInt64
  let elapsed: String
  let terminal: String?

  var id: Int32 {
    processID
  }

  var projectName: String? {
    guard let workingDirectory else {
      return nil
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if workingDirectory == home {
      return "~"
    }

    return URL(fileURLWithPath: workingDirectory).lastPathComponent
  }
}

struct RawProcessRecord: Equatable, Sendable {
  let processID: Int32
  let parentProcessID: Int32
  let userID: Int
  let cpuPercent: Double
  let residentKilobytes: UInt64
  let elapsed: String
  let terminal: String?
  let arguments: String
}

struct DevProcessClassificationInput: Sendable {
  let record: RawProcessRecord
  let listeningPorts: [Int]
  let workingDirectory: String?
  let memoryBytes: UInt64?
}

enum DevProcessClassifier {
  private static let agentExecutables: Set<String> = [
    "cursor-agent", "gemini", "aider", "droid", "opencode", "amp", "copilot",
    "coderabbit", "cr", "goose", "cline", "kiro", "jules",
  ]
  private static let runtimeExecutables: Set<String> = [
    "node", "bun", "deno", "npm", "pnpm", "yarn", "npx", "python", "python3", "ruby",
    "java", "go", "cargo", "php", "dotnet", "uvicorn", "gunicorn", "flask", "rails",
    "vite", "next", "next-server", "nuxt", "astro", "remix", "webpack", "turbo", "tsx",
    "ts-node", "nodemon", "live-server", "http-server", "serve", "wrangler", "vercel",
  ]
  private static let shellExecutables: Set<String> = ["zsh", "bash", "fish", "sh", "nu"]
  private static let genericRuntimes: Set<String> = [
    "node", "bun", "deno", "python", "python3", "ruby", "java", "npx", "tsx", "ts-node", "php",
    "dotnet",
  ]
  private static let genericScriptNames: Set<String> = [
    "cli", "cli.js", "index.js", "index.mjs", "main.js", "server.js", "start.js", "bin", "dist",
    "lib",
    ".bin", "node_modules", "src", "build", "out",
  ]

  static func classify(_ input: DevProcessClassificationInput) -> DevProcess? {
    let record = input.record
    let tokens = argumentTokens(record.arguments)
    guard let executable = tokens.first else {
      return nil
    }

    let executableName = AIThreadGrouping.executableName(record.arguments)
    let memoryBytes = input.memoryBytes ?? record.residentKilobytes * 1_024

    func make(_ kind: DevProcessKind, name: String, detail: String) -> DevProcess {
      DevProcess(
        processID: record.processID,
        parentProcessID: record.parentProcessID,
        kind: kind,
        name: name,
        detail: detail,
        workingDirectory: input.workingDirectory,
        listeningPorts: input.listeningPorts,
        cpuPercent: record.cpuPercent,
        memoryBytes: memoryBytes,
        elapsed: record.elapsed,
        terminal: record.terminal
      )
    }

    if executableName == "claude" {
      if tokens.contains("--chrome-native-host") {
        return nil
      }

      let session = value(after: "--session-id", in: tokens).map { id in
        String(id.prefix(8))
      }
      let mode = tokens.contains("--output-format") ? "headless" : "interactive"
      let detail = [session.map { "session \($0)" }, mode].compactMap { $0 }.joined(
        separator: " · ")
      return make(.claudeCode, name: "Claude Code", detail: detail)
    }

    if executableName == "codex" {
      if tokens.contains("app-server") {
        let isHost = tokens.contains("--listen") == false
        return make(
          .codex,
          name: isHost ? "Codex app" : "Codex thread",
          detail: isHost ? "ChatGPT desktop host" : "app-server"
        )
      }

      let subcommand =
        tokens.dropFirst().first { token in
          !token.hasPrefix("-")
        } ?? "interactive"
      return make(.codex, name: "Codex CLI", detail: subcommand)
    }

    if agentExecutables.contains(executableName) {
      return make(.aiAgent, name: executableName, detail: summarize(tokens.dropFirst()))
    }

    if executableName == "launchd_sim" {
      return make(.simulator, name: "iOS Simulator", detail: "launchd_sim")
    }

    if runtimeExecutables.contains(executableName) {
      let summary = summarize(tokens.dropFirst())
      if !input.listeningPorts.isEmpty {
        let name =
          genericRuntimes.contains(executableName)
          ? (scriptName(tokens) ?? executableName)
          : executableName
        return make(.devServer, name: name, detail: summary)
      }

      if executableName == "npm" || executableName == "pnpm" || executableName == "yarn"
        || executableName == "bun",
        tokens.dropFirst().first == "run" || tokens.dropFirst().first == "dev"
      {
        return make(.devServer, name: "\(executableName) \(summary)", detail: "task")
      }

      return nil
    }

    if !input.listeningPorts.isEmpty, record.userID != 0,
      !executable.hasPrefix("/System/"), !executable.hasPrefix("/usr/libexec/"),
      !record.arguments.contains(".app/"), !record.arguments.contains("Application Support/")
    {
      return make(.listener, name: executableName, detail: summarize(tokens.dropFirst()))
    }

    if shellExecutables.contains(
      executableName.trimmingCharacters(in: CharacterSet(charactersIn: "-"))),
      let terminal = record.terminal, terminal != "??",
      tokens.count == 1
    {
      return make(.shell, name: executableName, detail: terminal)
    }

    return nil
  }

  static func argumentTokens(_ arguments: String) -> [String] {
    arguments.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
  }

  private static func value(after flag: String, in tokens: [String]) -> String? {
    guard let index = tokens.firstIndex(of: flag), index + 1 < tokens.count else {
      return nil
    }

    return tokens[index + 1]
  }

  private static func scriptName(_ tokens: [String]) -> String? {
    if URL(fileURLWithPath: tokens[0]).lastPathComponent == "java" {
      return javaMainName(tokens)
    }

    var index = 1
    while index < tokens.count, tokens[index].hasPrefix("-") {
      index += tokens[index].contains("=") ? 1 : 2
    }

    guard index < tokens.count else {
      return nil
    }

    let script = tokens[index]
    let components = script.split(separator: "/").map(String.init).reversed()
    for component in components where !genericScriptNames.contains(component) && !component.isEmpty
    {
      return component.replacingOccurrences(of: ".js", with: "").replacingOccurrences(
        of: ".mjs", with: "")
    }

    return nil
  }

  private static func javaMainName(_ tokens: [String]) -> String? {
    if let jarIndex = tokens.firstIndex(of: "-jar"), jarIndex + 1 < tokens.count {
      return URL(fileURLWithPath: tokens[jarIndex + 1]).deletingPathExtension().lastPathComponent
    }

    let mainClass = tokens.dropFirst().first { token in
      !token.hasPrefix("-") && !token.contains("/") && token.contains(".") && !token.hasPrefix("*")
    }
    return mainClass?.split(separator: ".").first.map(String.init)
  }

  private static func summarize(_ tokens: ArraySlice<String>) -> String {
    let visible = Set(["dev", "start", "build", "test", "run", "serve", "watch", "preview", "mcp"])
    return tokens.prefix(4).filter { visible.contains($0) }.joined(separator: " ")
  }
}

enum RawProcessParser {
  /// Rows of `ps -axo pid=,ppid=,uid=,pcpu=,rss=,etime=,tty=,args=`; nil when any row is not in that shape.
  static func records(_ output: String) -> [RawProcessRecord]? {
    guard let rows = ProcessTable.rows(.init(output: output, columns: 8)) else { return nil }
    var records: [RawProcessRecord] = []
    for columns in rows {
      guard let processID = Int32(columns[0]),
        let parentProcessID = Int32(columns[1]),
        let userID = Int(columns[2]),
        let cpuPercent = Double(columns[3].replacingOccurrences(of: ",", with: ".")),
        let residentKilobytes = UInt64(columns[4])
      else { return nil }
      let terminal = String(columns[6])
      records.append(
        RawProcessRecord(
          processID: processID,
          parentProcessID: parentProcessID,
          userID: userID,
          cpuPercent: cpuPercent,
          residentKilobytes: residentKilobytes,
          elapsed: String(columns[5]),
          terminal: terminal == "??" ? nil : terminal,
          arguments: String(columns[7])
        ))
    }
    return records
  }
}
