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
  let session = URLSession(configuration: config)
  defer { session.invalidateAndCancel() }
  let page = await download(site.home, from: session, allowPrefix: true)
  let pageURL = page?.url ?? site.home
  let declarations = page.map { declaredIcons(in: $0.data, relativeTo: pageURL) } ?? []
  let home = QuicklinkSite(pageURL)?.home ?? site.home
  for icon in declarations + [home.appending(path: "favicon.ico")] {
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
  let limit = 512 * 1024
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

private func declaredIcons(in data: Data, relativeTo page: URL) -> [URL] {
  let html = String(decoding: data, as: UTF8.self)
  let tags = html.matches(of: /(?i)<link\b(?:[^>"']|"[^"]*"|'[^']*')*>/)
  var icons: [URL] = []
  for tag in tags {
    let attrs = tag.0.matches(of: /(?i)\s(rel|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/)
    var rel = ""
    var href: String?
    for (_, name, quoted, single, bare) in attrs.map(\.output) {
      let value = String(quoted ?? single ?? bare ?? "")
      if name.lowercased() == "rel" { rel = value.lowercased() } else { href = value }
    }
    let relations = rel.split(whereSeparator: \.isWhitespace)
    guard
      relations.contains(where: { ["icon", "apple-touch-icon", "apple-touch-icon-precomposed"].contains($0) }
      ),
      let href, !href.isEmpty,
      let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: page)?.absoluteURL,
      url.user == nil, url.password == nil, QuicklinkSite(url) != nil, !icons.contains(url)
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
