import Foundation

enum DeveloperLocations {
  static var additionalProjectRoots: [String] {
    UserDefaults.standard.stringArray(forKey: "locations.projectRoots") ?? []
  }
}
