import CryptoKit
import Foundation

struct QuicklinkSite: Sendable {
  let home: URL

  init?(_ url: URL) {
    guard var origin = URLComponents(url: url, resolvingAgainstBaseURL: true),
      let scheme = origin.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = origin.host?.lowercased(), !host.isEmpty
    else { return nil }
    origin.scheme = scheme
    origin.host = host
    if origin.port == (scheme == "https" ? 443 : 80) { origin.port = nil }
    origin.user = nil
    origin.password = nil
    origin.path = "/"
    origin.query = nil
    origin.fragment = nil
    guard let home = origin.url else { return nil }
    self.home = home
  }

  func favicon(in directory: URL) -> URL {
    let digest = SHA256.hash(data: Data(home.absoluteString.utf8))
    let key = digest.map { String(format: "%02x", $0) }.joined()
    return directory.appending(path: "favicon-\(key).png")
  }
}
