import Foundation

@main
enum FreeSpaceEntry {
  static func main() {
    guard !CommandLine.arguments.contains("--purge-memory") else {
      return
    }
    BrandMigration.run()
    FreeSpaceApp.main()
  }
}
