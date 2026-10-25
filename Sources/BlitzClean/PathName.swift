import Foundation

enum PathName {
  /// The last path component, read from the string alone. `URL(fileURLWithPath:)` checks the disk to learn
  /// whether a path is a folder, which made name lookups the largest cost of an idle scan.
  static func last(_ path: String) -> String { (path as NSString).lastPathComponent }
}
