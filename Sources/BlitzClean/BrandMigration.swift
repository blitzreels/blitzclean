import Foundation

enum BrandMigration {
  static func run() {
    AppData.migrateLegacyFiles(.init(legacy: AppData.legacyDirectory, current: AppData.directory))
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: "blitzclean.migrated") else { return }
    if let previous = defaults.persistentDomain(forName: "fr.algomax.FreeSpace") {
      let prefixes = ["memory.", "disk.", "locations.", "workspace.", "menuBar."]
      for (key, value) in previous where prefixes.contains(where: { key.hasPrefix($0) }) {
        if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
      }
    }
    defaults.set(true, forKey: "blitzclean.migrated")
  }
}
