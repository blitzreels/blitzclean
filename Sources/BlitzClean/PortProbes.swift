import AppKit
import CryptoKit
import Foundation
import ImageIO

enum PortProbeKind: String, Equatable, Sendable {
  case web
  case api
  case text
  case silent

  var title: String {
    switch self {
    case .web:
      "Web app"
    case .api:
      "JSON API"
    case .text:
      "Text service"
    case .silent:
      "Not HTTP"
    }
  }
}

struct PortProbe: Equatable, Sendable {
  let port: Int
  let kind: PortProbeKind
  let title: String?
  let faviconData: Data?
  let finalURL: String?
  let probedAt: Date

  var label: String? {
    if let title, !title.isEmpty {
      return title
    }

    switch kind {
    case .api, .text:
      return kind.title
    case .web, .silent:
      return nil
    }
  }
}

enum HTMLMetadataParser {
  static func title(_ html: String) -> String? {
    let candidates = [
      firstMatch(html, pattern: "<title[^>]*>([^<]{1,200})</title>"),
      firstMatch(
        html,
        pattern: "<meta[^>]+property=[\"']og:site_name[\"'][^>]+content=[\"']([^\"']{1,120})[\"']"),
      firstMatch(
        html,
        pattern: "<meta[^>]+name=[\"']application-name[\"'][^>]+content=[\"']([^\"']{1,120})[\"']"),
    ]

    for candidate in candidates {
      if let candidate {
        let cleaned = decodeEntities(candidate)
          .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
          return String(cleaned.prefix(90))
        }
      }
    }

    return nil
  }

  static func iconHref(_ html: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: "<link[^>]+>", options: [.caseInsensitive])
    else {
      return nil
    }

    let range = NSRange(html.startIndex..., in: html)
    var fallback: String?
    for match in regex.matches(in: html, options: [], range: range) {
      guard let tagRange = Range(match.range, in: html) else {
        continue
      }

      let tag = String(html[tagRange])
      guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
        let href = attribute("href", in: tag), !href.isEmpty
      else {
        continue
      }

      if rel.contains("apple-touch") {
        fallback = fallback ?? href
        continue
      }

      return href
    }

    return fallback
  }

  static func attribute(_ name: String, in tag: String) -> String? {
    firstMatch(tag, pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']")
      ?? firstMatch(tag, pattern: "\\b\(name)\\s*=\\s*([^\\s\"'>]+)")
  }

  private static func firstMatch(_ text: String, pattern: String) -> String? {
    guard
      let regex = try? NSRegularExpression(
        pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
      let match = regex.firstMatch(
        in: text, options: [], range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: text)
    else {
      return nil
    }

    return String(text[range])
  }

  private static func decodeEntities(_ text: String) -> String {
    var result = text
    let replacements = [
      "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
      "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&#8212;": "—", "&#x27;": "'",
    ]
    for (entity, value) in replacements {
      result = result.replacingOccurrences(of: entity, with: value)
    }

    return result
  }
}

enum LoopbackProbePolicy {
  static func allows(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.user == nil, url.password == nil
    else { return false }
    return ["127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
  }
}

final class LoopbackRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(request.url.map(LoopbackProbePolicy.allows) == true ? request : nil)
  }
}

struct PortProber: Sendable {
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2.5
    configuration.timeoutIntervalForResource = 4
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpAdditionalHeaders = ["Accept": "text/html,application/json;q=0.9,*/*;q=0.5"]
    configuration.connectionProxyDictionary = [:]
    session = URLSession(
      configuration: configuration, delegate: LoopbackRedirectDelegate(), delegateQueue: nil)
  }

  func probe(port: Int) async -> PortProbe {
    for host in ["127.0.0.1", "[::1]"] {
      guard let url = URL(string: "http://\(host):\(port)/"),
        let (data, response) = try? await session.data(from: url),
        let http = response as? HTTPURLResponse
      else { continue }
      return await classify(.init(port: port, url: url, data: data, response: http))
    }
    return silent(port)
  }

  private struct Response {
    let port: Int
    let url: URL
    let data: Data
    let response: HTTPURLResponse
  }

  private func classify(_ input: Response) async -> PortProbe {
    let port = input.port
    let http = input.response
    let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    let body = String(decoding: input.data.prefix(256_000), as: UTF8.self)
    let finalURL = http.url?.absoluteString

    if contentType.contains("json") {
      return PortProbe(
        port: port, kind: .api, title: nil, faviconData: nil, finalURL: finalURL, probedAt: .now)
    }

    if contentType.contains("html") || body.range(of: "<html", options: .caseInsensitive) != nil {
      let title = HTMLMetadataParser.title(body)
      let favicon = await favicon(.init(base: http.url ?? input.url, html: body))
      return PortProbe(
        port: port, kind: .web, title: title, faviconData: favicon, finalURL: finalURL,
        probedAt: .now)
    }

    let firstLine = body.split(whereSeparator: \.isNewline).first.map { line in
      String(line.trimmingCharacters(in: .whitespaces).prefix(60))
    }
    return PortProbe(
      port: port,
      kind: .text,
      title: firstLine?.isEmpty == false ? firstLine : nil,
      faviconData: nil,
      finalURL: finalURL,
      probedAt: .now
    )
  }

  private struct IconRequest {
    let base: URL
    let html: String
  }

  private func favicon(_ input: IconRequest) async -> Data? {
    let base = input.base
    let html = input.html
    var candidates: [URL] = []
    if let href = HTMLMetadataParser.iconHref(html) {
      if href.hasPrefix("data:") {
        return dataURIPayload(href)
      }

      if let resolved = URL(string: href, relativeTo: base)?.absoluteURL {
        candidates.append(resolved)
      }
    }

    if let root = URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL {
      candidates.append(root)
    }

    for candidate in candidates where LoopbackProbePolicy.allows(candidate) {
      guard let (data, response) = try? await session.data(from: candidate),
        let http = response as? HTTPURLResponse, http.statusCode == 200,
        data.count > 16, data.count < 2_000_000,
        NSImage(data: data) != nil
      else {
        continue
      }

      return data
    }

    return nil
  }

  private func dataURIPayload(_ uri: String) -> Data? {
    guard let comma = uri.firstIndex(of: ",") else {
      return nil
    }

    let header = uri[uri.index(after: uri.startIndex)..<comma]
    let payload = String(uri[uri.index(after: comma)...])
    if header.contains("base64") {
      return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    }

    return payload.removingPercentEncoding?.data(using: .utf8)
  }

  private func silent(_ port: Int) -> PortProbe {
    PortProbe(
      port: port, kind: .silent, title: nil, faviconData: nil, finalURL: nil, probedAt: .now)
  }
}
