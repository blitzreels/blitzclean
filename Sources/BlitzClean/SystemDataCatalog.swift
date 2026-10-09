import Foundation

enum SystemDataCatalog {
  static func rules(home: String) -> [CacheRule] {
    [
      .init(
        title: "Safari cache", path: home + "/Library/Caches/com.apple.Safari",
        recipe: "Safari downloads cached content again. History and saved passwords stay.",
        owners: ["Safari", "com.apple.WebKit.Networking", "com.apple.WebKit.WebContent"],
        kind: .cache),
      .init(
        title: "Chrome cache", path: home + "/Library/Caches/Google/Chrome",
        recipe: "Chrome downloads cached content again. Browser profiles stay.",
        owners: [
          "Google Chrome", "Google Chrome Helper", "Google Chrome Helper (Renderer)",
          "Google Chrome Helper (GPU)",
        ],
        kind: .cache),
      .init(
        title: "Firefox cache", path: home + "/Library/Caches/Firefox",
        recipe: "Firefox downloads cached content again. Browser profiles stay.",
        owners: ["firefox", "plugin-container"], kind: .cache),
      .init(
        title: "Diagnostic reports", path: home + "/Library/Logs/DiagnosticReports",
        recipe: "Crash and hang reports older than 30 days. Deleted reports cannot be recovered.",
        owners: ["ReportCrash", "CrashReporter"], kind: .diagnosticReport),
    ]
  }
}
