import AppKit
import ImageIO
import UniformTypeIdentifiers

func cacheFavicon(for url: URL) async {
  guard let site = QuicklinkSite(url),
    let dataPath = ProcessInfo.processInfo.environment["WICKET_DATA_DIR"], !dataPath.isEmpty
  else { return }
  let file = site.favicon(in: URL(filePath: dataPath, directoryHint: .isDirectory))
  guard !FileManager.default.fileExists(atPath: file.path) else { return }
  let config = URLSessionConfiguration.ephemeral
  config.httpShouldSetCookies = false
  config.httpCookieStorage = nil
  config.urlCredentialStorage = nil
  config.urlCache = nil
  config.timeoutIntervalForRequest = 1.25
  config.timeoutIntervalForResource = 1.25
  let session = URLSession(configuration: config, delegate: FaviconRedirects(site: site), delegateQueue: nil)
  defer { session.invalidateAndCancel() }
  let page = await download(site.home, from: session, allowPrefix: true)
  let pageURL = page?.url ?? site.home
  let origin = QuicklinkSite(pageURL) ?? site
  let declarations = page.map { declaredIcons(in: $0.data, relativeTo: pageURL, origin: origin) } ?? []
  for icon in declarations + [origin.home.appending(path: "favicon.ico")] {
    guard let data = await download(icon, from: session)?.data, let image = faviconImage(data),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { continue }
    try? png.write(to: file, options: .atomic)
    return
  }
}

private func download(
  _ url: URL, from session: URLSession, allowPrefix: Bool = false
) async -> (data: Data, url: URL)? {
  let limit = allowPrefix ? 512 * 1024 : IconRaster.maxIconBytes
  do {
    let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let url = http.url, QuicklinkSite(url) != nil, allowPrefix || http.expectedContentLength <= limit
    else { return nil }
    var body = Data()
    if http.expectedContentLength > 0 {
      body.reserveCapacity(Int(min(http.expectedContentLength, Int64(limit))))
    }
    for try await byte in bytes {
      guard body.count < limit else { return nil }
      body.append(byte)
      if allowPrefix && body.count == limit { break }
    }
    return (body, url)
  } catch {
    return nil
  }
}

extension QuicklinkSite {
  fileprivate func allows(_ url: URL) -> Bool {
    guard url.user == nil, url.password == nil, let destination = QuicklinkSite(url) else { return false }
    if home == destination.home { return true }
    let next = destination.home
    return home.scheme == "http" && next.scheme == "https" && home.host == next.host
      && (home.port.map { $0 == (next.port ?? 443) } ?? (next.port == nil))
  }
}

private final class FaviconRedirects: NSObject, URLSessionTaskDelegate {
  let site: QuicklinkSite
  init(site: QuicklinkSite) { self.site = site }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let url = request.url, site.allows(url),
      response.url.flatMap(QuicklinkSite.init)?.allows(url) == true
    else { return nil }
    return request
  }
}

private func declaredIcons(in data: Data, relativeTo page: URL, origin: QuicklinkSite) -> [URL] {
  let html = String(decoding: data, as: UTF8.self)
  let tags = html.matches(of: /(?i)<(base|link)\b(?:[^>"']|"[^"]*"|'[^']*')*>/)
  func attribute(_ name: String, in tag: Substring) -> String? {
    for match in tag.matches(of: /(?i)\s(rel|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>\x60]+))/) {
      let (_, key, quoted, single, bare) = match.output
      if key.lowercased() == name { return (quoted ?? single ?? bare).map(String.init) }
    }
    return nil
  }
  func resolve(_ href: String, relativeTo url: URL) -> URL? {
    URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: url)?.absoluteURL
  }
  let base =
    tags.lazy.filter { $0.1.lowercased() == "base" }
    .compactMap { attribute("href", in: $0.0) }.first.flatMap { resolve($0, relativeTo: page) } ?? page
  var icons: [URL] = []
  for tag in tags where tag.1.lowercased() == "link" {
    let relations = attribute("rel", in: tag.0)?.lowercased().split(whereSeparator: \.isWhitespace) ?? []
    guard
      relations.contains(where: { ["icon", "apple-touch-icon", "apple-touch-icon-precomposed"].contains($0) }
      ),
      let href = attribute("href", in: tag.0), !href.isEmpty,
      let url = resolve(href, relativeTo: base), origin.allows(url), !icons.contains(url)
    else { continue }
    icons.append(url)
    if icons.count == 2 { break }
  }
  return icons
}

private func faviconImage(_ data: Data) -> CGImage? {
  let maxSize = 128
  if let source = CGImageSourceCreateWithData(data as CFData, nil),
    let kind = CGImageSourceGetType(source) as String?,
    [UTType.ico, .png, .jpeg, .gif, .webP, .bmp].contains(where: { $0.identifier == kind })
  {
    if kind != UTType.ico.identifier { return IconRaster.thumbnail(source, maxSize: maxSize) }
    for index in (0..<CGImageSourceGetCount(source)).reversed() {
      if let image = IconRaster.thumbnail(source, index: index, maxSize: maxSize) { return image }
    }
    return nil
  }
  return IconRaster.svg(data, maxSize: maxSize)
}
