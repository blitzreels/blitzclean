import Foundation
import Network
import Testing

@testable import BlitzClean

struct PortProbeTests {
  @Test func probesIPv6OnlyLoopbackServers() async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "::1", port: .any)
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "blitzclean.tests.ipv6")
    let states = AsyncStream<NWListener.State> { continuation in
      listener.stateUpdateHandler = { continuation.yield($0) }
    }
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
        let reply =
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}"
        connection.send(
          content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: queue)
    defer { listener.cancel() }
    for await state in states {
      if case .failed(let error) = state { throw error }
      if case .ready = state { break }
    }
    let port = try #require(listener.port)
    let result = await PortProber().probe(port: Int(port.rawValue))
    #expect(result.kind == .api)
    #expect(result.finalURL?.contains("[::1]") == true)
  }

  @Test func restrictsProbeAndIconDestinationsToLiteralLoopback() throws {
    for value in ["http://127.0.0.1:3000/", "https://[::1]:443/icon.png"] {
      #expect(LoopbackProbePolicy.allows(try #require(URL(string: value))))
    }
    for value in [
      "https://example.com/icon.png", "http://127.0.0.1.example.com/", "http://localhost/",
      "http://192.168.1.1/", "file:///etc/passwd", "http://user:password@127.0.0.1/",
    ] {
      #expect(!LoopbackProbePolicy.allows(try #require(URL(string: value))))
    }
  }

  @Test func refusesExternalRedirectBeforeFollowingIt() throws {
    let delegate = LoopbackRedirectDelegate()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let source = try #require(URL(string: "http://127.0.0.1:3000/"))
    let task = session.dataTask(with: source)
    let response = try #require(
      HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil))
    for destination in ["https://example.com/", "http://127.0.0.1:3000/next"] {
      let request = URLRequest(url: try #require(URL(string: destination)))
      delegate.urlSession(
        session, task: task, willPerformHTTPRedirection: response, newRequest: request
      ) { redirected in
        #expect((redirected != nil) == destination.contains("127.0.0.1"))
      }
    }
  }

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
