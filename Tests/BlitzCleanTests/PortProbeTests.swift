import Foundation
import Testing

@testable import BlitzClean

struct PortProbeTests {
  @Test
  func extractsTitleAndDecodesEntities() {
    let html = "<html><head><title>\n  Alarya &mdash; Elle &amp; lui </title></head></html>"
    #expect(HTMLMetadataParser.title(html) == "Alarya — Elle & lui")
  }

  @Test
  func fallsBackToSiteName() {
    let html = "<meta property=\"og:site_name\" content=\"BlitzReels\">"
    #expect(HTMLMetadataParser.title(html) == "BlitzReels")
    #expect(HTMLMetadataParser.title("<p>no title</p>") == nil)
  }

  @Test
  func prefersStandardIconOverAppleTouch() {
    let html = """
      <link rel="apple-touch-icon" href="/apple.png">
      <link rel="shortcut icon" href="/logos/icon.png"/>
      <link rel="icon" href="/icon.svg?x=1" sizes="any" type="image/svg+xml"/>
      """
    #expect(HTMLMetadataParser.iconHref(html) == "/logos/icon.png")
    #expect(
      HTMLMetadataParser.iconHref("<link rel=\"apple-touch-icon\" href=\"/apple.png\">")
        == "/apple.png")
    #expect(HTMLMetadataParser.iconHref("<link rel=\"stylesheet\" href=\"/a.css\">") == nil)
  }

  @Test
  func labelsAPIsAndTextServicesWithoutTitles() {
    let api = PortProbe(
      port: 1, kind: .api, title: nil, faviconData: nil, finalURL: nil, probedAt: .now)
    let web = PortProbe(
      port: 2, kind: .web, title: nil, faviconData: nil, finalURL: nil, probedAt: .now)
    #expect(api.label == "JSON API")
    #expect(web.label == nil)
  }
}

struct LivePortProbeTests {
  @Test
  func probesLivePortsWhenRequested() async {
    guard let list = ProcessInfo.processInfo.environment["BLITZCLEAN_PROBE_PORTS"] else {
      return
    }

    let prober = PortProber()
    for port in list.split(separator: ",").compactMap({ Int($0) }) {
      let probe = await prober.probe(port: port)
      print(
        "PROBE", port, probe.kind.rawValue, probe.label ?? "-", "favicon:",
        probe.faviconData?.count ?? 0, "bytes")
    }
  }
}
