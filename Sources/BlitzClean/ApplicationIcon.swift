import AppKit
import Darwin
import SwiftUI

enum ApplicationIconSource: Hashable {
  case process(Int32)
  case name(String)
  case file(String)
  case storage(String)
}

@MainActor
enum ApplicationIconResolver {
  private static var installed: [String: URL] = [:]
  private static var checked: Set<String> = []

  private static func application(_ name: String) -> URL? {
    if checked.contains(name) { return installed[name] }
    checked.insert(name)
    let ids = StorageOwner.named(name)?.bundleIDs ?? [name]
    let url = ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
      .first
    if let url { installed[name] = url }
    return url
  }
  static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 128
    return cache
  }()

  static func image(_ source: ApplicationIconSource) -> NSImage? {
    let path: String
    switch source {
    case .process(let pid):
      var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
        return NSRunningApplication(processIdentifier: pid)?.icon
      }
      let executable = String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      guard let range = executable.range(of: ".app/") else { return nil }
      path = String(executable[..<range.lowerBound]) + ".app"
    case .name(let name):
      if let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
          || $0.bundleIdentifier == name
      }), let image = app.icon {
        return image
      }
      guard let url = application(name) else { return nil }
      path = url.path
    case .file(let value):
      let name = PathName.last(value)
      path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)?.path ?? value
    case .storage(let value):
      if let owner = StorageOwner.forPath(value), let url = application(owner.rawValue) {
        path = url.path
      } else {
        path = value
      }
    }
    if let cached = cache.object(forKey: path as NSString) { return cached }
    let image = NSWorkspace.shared.icon(forFile: path)
    cache.setObject(image, forKey: path as NSString)
    return image
  }
}

struct ApplicationIcon: View {
  let source: ApplicationIconSource
  let size: CGFloat
  let fallback: String
  @State private var icon: NSImage?

  var body: some View {
    Group {
      if let icon {
        Image(nsImage: icon).resizable().scaledToFit()
      } else {
        Image(systemName: fallback).resizable().scaledToFit().padding(5)
          .foregroundStyle(.secondary)
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
      .task(id: source) { icon = ApplicationIconResolver.image(source) }
  }
}
