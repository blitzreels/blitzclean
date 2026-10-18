import Foundation

@main
enum BlitzCleanEntry {
  @MainActor static func main() {
    guard !CommandLine.arguments.contains("--purge-memory") else {
      return
    }
    if CommandLine.arguments.contains("--emergency-controls")
      || Bundle.main.bundleIdentifier == "com.blitzreels.BlitzClean.Emergency"
    {
      EmergencyControls.run()
      return
    }
    BrandMigration.run()
    EmergencyControlsLauncher.start()
    BlitzCleanApp.main()
  }
}
