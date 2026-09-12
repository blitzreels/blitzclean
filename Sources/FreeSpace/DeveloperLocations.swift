import Foundation

enum DeveloperLocations {
  static var volumePath: String? {
    guard let value = UserDefaults.standard.string(forKey: "locations.developerVolume"),
      !value.isEmpty
    else { return nil }
    return value
  }

  static var additionalProjectRoots: [String] {
    UserDefaults.standard.stringArray(forKey: "locations.projectRoots") ?? []
  }
}
