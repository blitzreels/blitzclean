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
  @MainActor static let icon = resourceImage("AppIcon.icns")
  @MainActor static let mark = resourceImage("Mark.svg")
  @MainActor static let makerWordmark = resourceImage("BlitzReelsWordmark.png")
  static let repositoryURL = URL(string: "https://github.com/blitzreels/blitzclean")!

  /// Other products by BlitzReels, linked from Settings and the menu bar panel.
  static let family: [FamilyApp] = [
    .init(
      name: "BlitzRecorder", detail: "Free, open-source screen and camera recorder with an editor.",
      url: URL(string: "https://blitzrecorder.com")!, iconFile: "BlitzRecorder.png"),
    .init(
      name: "BlitzReels", detail: "Turns long videos into short clips with captions and reframing.",
      url: URL(string: "https://blitzreels.com")!, iconFile: "BlitzReels.png"),
  ]

  /// An image bundled in the app's Resources; absent when running outside the app bundle.
  @MainActor static func resourceImage(_ file: String) -> NSImage? {
    let name = (file as NSString).deletingPathExtension
    let ext = (file as NSString).pathExtension
    return Bundle.main.url(forResource: name, withExtension: ext).flatMap(NSImage.init(contentsOf:))
  }
}

struct FamilyApp: Identifiable {
  let name: String
  let detail: String
  let url: URL
  let iconFile: String

  var id: String { name }
}

/// A full-row link to another BlitzReels product.
struct FamilyAppRow: View {
  let app: FamilyApp

  var body: some View {
    Button {
      NSWorkspace.shared.open(app.url)
    } label: {
      HStack(spacing: 12) {
        Group {
          if let icon = AppBrand.resourceImage(app.iconFile) {
            Image(nsImage: icon).resizable().scaledToFit()
          } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BlitzUI.controlFill)
          }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text(app.name).font(BlitzType.rowTitle)
          Text(app.detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Text(app.url.host() ?? "").font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      .padding(.horizontal, 12).frame(minHeight: 52).contentShape(Rectangle())
    }
    .buttonStyle(BlitzRowButtonStyle(radius: 8))
    .help("Open \(app.url.absoluteString)")
    .accessibilityLabel("\(app.name), \(app.detail) Opens \(app.url.host() ?? "") in your browser.")
  }
}

struct BrandMark: View {
  var body: some View {
    Group {
      if let icon = AppBrand.icon {
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
