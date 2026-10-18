import AppKit
import Foundation

/// Where a project's own logo comes from: an image in its folder, or the app it builds.
enum ProjectLogoSource: Equatable, Sendable {
  case file(String)
  case app(String)

  @MainActor var image: NSImage? {
    switch self {
    case .file(let path): NSImage(contentsOfFile: path)
    case .app(let path): NSWorkspace.shared.icon(forFile: path)
    }
  }
}

enum ProjectLogo {
  private static let skipped: Set<String> = [
    "node_modules", ".git", ".next", ".build", "dist", "build", "outputs", "Pods", "DerivedData",
    ".turbo", "coverage", "vendor", ".venv", "venv", "__pycache__", "tmp", ".cache", "fixtures",
    "test", "tests", "__tests__", "e2e", "stories", "storybook-static", ".expo", "ios", "android",
  ]

  struct Candidate: Equatable {
    let path: String
    let score: Int
  }

  struct ScoreInput {
    let name: String
    let depth: Int
    let path: String
  }

  /// Ranks one file name; nil when it is not a logo. Higher is better.
  static func score(_ input: ScoreInput) -> Int? {
    let name = input.name.lowercased()
    let base: Int
    if name.hasPrefix("apple-touch-icon"), name.hasSuffix(".png") {
      base = 100
    } else if name.hasSuffix(".icns") || name.hasPrefix("appicon") && name.hasSuffix(".png") {
      base = 95
    } else if ["icon.png", "apple-icon.png", "icon-512.png", "icon-192.png", "app-icon.png"]
      .contains(name)
    {
      base = 90
    } else if name == "logo.png" || name == "logo-mark.png" {
      base = 72
    } else if ["icon.svg", "favicon.svg", "logo-mark.svg"].contains(name) {
      base = 65
    } else if name.hasPrefix("favicon"), name.hasSuffix(".png") {
      base = 60
    } else if name == "logo.svg" {
      base = 50
    } else if name == "favicon.ico" {
      base = 45
    } else {
      return nil
    }
    let lower = input.path.lowercased()
    let penalty = ["/docs/", "/example", "/demo", "/sample", "/mock"].contains {
      lower.contains($0)
    }
    return base - input.depth * 4 - (penalty ? 30 : 0)
  }

  /// The best logo inside a project, or the app it builds; bounded so it stays fast on large repos.
  static func find(_ directory: String) -> ProjectLogoSource? {
    if let app = installedApp(directory) { return .app(app) }
    var candidates: [Candidate] = []
    var queue: [(path: String, depth: Int)] = [(directory, 0)]
    var visited = 0
    while !queue.isEmpty, visited < 600 {
      let (folder, depth) = queue.removeFirst()
      visited += 1
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
        continue
      }
      for name in names {
        let path = folder + "/" + name
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
          continue
        }
        if isDirectory.boolValue {
          if name.hasSuffix(".appiconset"), let icon = largestPNG(path) {
            candidates.append(.init(path: icon, score: 95 - depth * 4))
          } else if depth < 5, !skipped.contains(name), !name.hasPrefix("."),
            !name.hasSuffix(".app"), !name.hasSuffix(".xcodeproj")
          {
            queue.append((path, depth + 1))
          }
        } else if let score = score(.init(name: name, depth: depth, path: path)) {
          candidates.append(.init(path: path, score: score))
        }
      }
    }
    for candidate in candidates.sorted(by: { $0.score > $1.score }).prefix(8) {
      guard let image = NSImage(contentsOfFile: candidate.path), image.size.width > 0,
        image.size.height > 0
      else { continue }
      let ratio = image.size.width / image.size.height
      if ratio > 0.66, ratio < 1.5 { return .file(candidate.path) }
    }
    return nil
  }

  /// An app named like the project in Applications or the project's own build folder.
  private static func installedApp(_ directory: String) -> String? {
    let name = URL(fileURLWithPath: directory).lastPathComponent.lowercased()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for folder in ["/Applications", home + "/Applications", directory + "/dist"] {
      guard let apps = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
        continue
      }
      if let app = apps.first(where: { $0.lowercased() == name + ".app" }) {
        return folder + "/" + app
      }
    }
    return nil
  }

  private static func largestPNG(_ folder: String) -> String? {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    return files.filter { $0.lowercased().hasSuffix(".png") }
      .compactMap { name -> (String, Int)? in
        let path = folder + "/" + name
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return (path, size)
      }
      .max { $0.1 < $1.1 }?.0
  }
}

/// Logo lookups by project folder; a folder is searched at most once every ten minutes.
actor ProjectLogoCache {
  static let shared = ProjectLogoCache()
  private var values: [String: (date: Date, source: ProjectLogoSource?)] = [:]

  func source(_ directory: String) -> ProjectLogoSource? {
    if let entry = values[directory], Date().timeIntervalSince(entry.date) < 600 {
      return entry.source
    }
    let source = ProjectLogo.find(directory)
    values[directory] = (.now, source)
    return source
  }
}
