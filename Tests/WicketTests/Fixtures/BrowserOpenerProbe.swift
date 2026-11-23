import Foundation

extension BrowserOpener {
  static var system: Self {
    Self(
      application: { $0 == "test.browser" ? URL(fileURLWithPath: "/Probe.app") : nil },
      open: { url, application in
        let evidence = url.absoluteString + (application.map { "\n" + $0.path } ?? "")
        try evidence.write(to: URL(fileURLWithPath: "opened"), atomically: true, encoding: .utf8)
      })
  }
}
