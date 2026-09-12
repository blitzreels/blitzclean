import Foundation
import SwiftUI

enum ProjectTechnology: String, Sendable, CaseIterable {
  case next = "Next.js"
  case tanstack = "TanStack"
  case node = "Node.js"
  case react = "React"
  case vite = "Vite"
  case swift = "Swift"
  case python = "Python"
  case unknown = "Project"

  struct Input: Sendable {
    let directory: String?
    let processName: String
  }

  static func detect(_ input: Input) -> Self {
    let process = input.processName.lowercased()
    if process == "next" || process.hasPrefix("next-server") { return .next }
    var directory = input.directory.map { URL(fileURLWithPath: $0) }
    for _ in 0..<8 {
      guard let current = directory, current.path != "/" else { break }
      let manifest = current.appendingPathComponent("package.json")
      if let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= 1_048_576,
        let data = try? Data(contentsOf: manifest),
        let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        let names = Set(
          ["dependencies", "devDependencies", "peerDependencies"].flatMap {
            Array((package[$0] as? [String: Any] ?? [:]).keys)
          })
        if names.contains("next") { return .next }
        if names.contains(where: {
          $0.hasPrefix("@tanstack/") && ($0.contains("start") || $0.contains("router"))
        }) {
          return .tanstack
        }
        if names.contains("react") { return .react }
        if names.contains("vite") { return .vite }
        if names.contains(where: { $0.hasPrefix("@tanstack/") }) { return .tanstack }
        return .node
      }
      if FileManager.default.fileExists(
        atPath: current.appendingPathComponent("Package.swift").path)
      {
        return .swift
      }
      if FileManager.default.fileExists(
        atPath: current.appendingPathComponent("pyproject.toml").path)
      {
        return .python
      }
      if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
        break
      }
      directory = current.deletingLastPathComponent()
    }
    if process.contains("node") || process.contains("npm") { return .node }
    if process.contains("python") { return .python }
    if process.contains("vite") { return .vite }
    return .unknown
  }
}

actor ProjectTechnologyCache {
  static let shared = ProjectTechnologyCache()
  private var values: [String: (date: Date, value: ProjectTechnology)] = [:]

  func value(_ input: ProjectTechnology.Input) -> ProjectTechnology {
    let key = (input.directory ?? "") + "\n" + input.processName
    if let entry = values[key], Date().timeIntervalSince(entry.date) < 60 { return entry.value }
    if values.count >= 256 {
      values = values.filter { Date().timeIntervalSince($0.value.date) < 60 }
      if values.count >= 256 { values.removeAll(keepingCapacity: true) }
    }
    let value = ProjectTechnology.detect(input)
    values[key] = (.now, value)
    return value
  }
}

struct ProjectIcon: View {
  let directory: String?
  let processName: String
  let size: CGFloat
  let fallbackSymbol: String
  @State private var technology: ProjectTechnology = .unknown

  var body: some View {
    Group {
      if technology == .unknown {
        Image(systemName: fallbackSymbol).font(.system(size: size * 0.6))
          .foregroundStyle(AppBrand.accent).frame(width: size, height: size)
      } else {
        TechnologyIcon(technology: technology, size: size)
      }
    }
    .task(id: (directory ?? "") + "\n" + processName) {
      let value = await ProjectTechnologyCache.shared.value(
        .init(directory: directory, processName: processName))
      if !Task.isCancelled { technology = value }
    }
  }
}

struct TechnologyIcon: View {
  let technology: ProjectTechnology
  let size: CGFloat

  private var color: Color {
    switch technology {
    case .next: .primary
    case .tanstack: .orange
    case .node: .green
    case .react: .cyan
    case .vite: .purple
    case .swift: .orange
    case .python: .blue
    case .unknown: AppBrand.accent
    }
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.24).fill(color.opacity(0.12))
      switch technology {
      case .next:
        Circle().fill(Color.primary).padding(size * 0.08)
        Text("N").font(.system(size: size * 0.58, weight: .semibold))
          .foregroundStyle(Color(nsColor: .windowBackgroundColor))
      case .node:
        Image(systemName: "hexagon.fill").font(.system(size: size * 0.83)).foregroundStyle(.green)
        Text("n").font(.system(size: size * 0.52, weight: .bold)).foregroundStyle(.white)
      case .tanstack:
        Image(systemName: "sun.max.fill").font(.system(size: size * 0.57))
          .foregroundStyle(.orange).offset(x: size * 0.1, y: -size * 0.08)
        Image(systemName: "palm.tree.fill").font(.system(size: size * 0.7))
          .foregroundStyle(.teal).offset(x: -size * 0.08, y: size * 0.04)
      default:
        Image(systemName: symbol).font(.system(size: size * 0.59)).foregroundStyle(color)
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel(technology.rawValue)
    .help(technology.rawValue)
  }

  private var symbol: String {
    switch technology {
    case .react: "atom"
    case .vite: "bolt.fill"
    case .swift: "swift"
    case .python: "curlybraces"
    default: "folder.fill"
    }
  }
}
