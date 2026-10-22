import Foundation

@main
enum BlitzCleanEntry {
  @MainActor static func main() {
    guard !CommandLine.arguments.contains("--purge-memory") else {
      return
    }
    if CommandLine.arguments.contains("--emergency-controls")
      || Bundle.main.bundleIdentifier?.hasSuffix(".Emergency") == true
    {
      EmergencyControls.run()
      return
    }
    if !AppBrand.isDevelopmentBuild { BrandMigration.run() }
    EmergencyControlsLauncher.start()
    BlitzCleanApp.main()
  }
}
