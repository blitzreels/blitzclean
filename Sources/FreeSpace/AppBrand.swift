import AppKit
import SwiftUI

enum AppBrand {
  static let name = "BlitzClean"
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development"
  }
  static let accent = BlitzUI.mint
  static let bundleIdentifier = "com.blitzreels.BlitzClean"
  static let repositoryURL = URL(string: "https://github.com/blitzreels/blitzclean")!
}

struct BrandMark: View {
  var body: some View {
    Group {
      if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
        let icon = NSImage(contentsOf: url)
      {
        Image(nsImage: icon).resizable().scaledToFit()
      } else {
        fallback
      }
    }
    .frame(width: 40, height: 40)
    .accessibilityLabel(AppBrand.name)
  }

  private var fallback: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10).fill(BlitzUI.sidebarBackground)
      Image(systemName: "bolt.fill")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(AppBrand.accent)
    }
  }
}
