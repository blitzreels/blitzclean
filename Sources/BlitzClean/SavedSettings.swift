import Foundation

/// Reads saved settings one entry at a time, so an entry another build cannot read does not discard
/// the rest. When anything was unreadable, the original value is copied to `<key>.unreadable` first,
/// before a later save can overwrite it.
enum SavedSettings {
  struct Request {
    let key: String
    let defaults: UserDefaults
  }

  /// Nil when a value is stored but is not a list at all; an empty list when nothing is stored.
  static func list<Element: Decodable>(_ request: Request) -> [Element]? {
    guard let data = request.defaults.data(forKey: request.key) else { return [] }
    guard let entries = try? JSONDecoder().decode([Lossy<Element>].self, from: data) else {
      preserve(.init(data: data, request: request))
      return nil
    }
    let values = entries.compactMap(\.value)
    if values.count != entries.count { preserve(.init(data: data, request: request)) }
    return values
  }

  /// Nil when a value is stored but is not a dictionary at all.
  static func dictionary<Value: Decodable>(_ request: Request) -> [String: Value]? {
    guard let data = request.defaults.data(forKey: request.key) else { return [:] }
    guard let entries = try? JSONDecoder().decode([String: Lossy<Value>].self, from: data) else {
      preserve(.init(data: data, request: request))
      return nil
    }
    let values = entries.compactMapValues(\.value)
    if values.count != entries.count { preserve(.init(data: data, request: request)) }
    return values
  }

  private struct Preservation {
    let data: Data
    let request: Request
  }

  private static func preserve(_ input: Preservation) {
    let backup = input.request.key + ".unreadable"
    guard input.request.defaults.data(forKey: backup) == nil else { return }
    input.request.defaults.set(input.data, forKey: backup)
  }
}

/// Decodes to nil instead of failing, so one unreadable element does not fail its whole list.
struct Lossy<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}
