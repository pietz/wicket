import Foundation
import Synchronization

func httpURL(_ string: String) -> URL? {
  guard let url = URL(string: string), isHTTP(url) else { return nil }
  return url
}

private func isHTTP(_ url: URL) -> Bool {
  let scheme = url.scheme?.lowercased()
  return (scheme == "http" || scheme == "https") && url.host(percentEncoded: false)?.isEmpty == false
}

func fetch(_ request: URLRequest, deadline: UInt64) throws -> [String: Any] {
  let config = URLSessionConfiguration.ephemeral
  config.httpShouldSetCookies = false
  config.httpCookieStorage = nil
  config.urlCredentialStorage = nil
  config.urlCache = nil
  let transfer = FetchTransfer()
  let session = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
  defer { session.invalidateAndCancel() }
  let task = session.dataTask(with: request)
  guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure("timed out") }
  task.resume()
  guard transfer.completed.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .success else {
    throw Failure("timed out")
  }
  return try transfer.result(task.response)
}

private final class FetchTransfer: NSObject, URLSessionDataDelegate {
  private struct State {
    var body = Data()
    var redirects = 0
    var failure: (any Error)?
  }

  private let state = Mutex(State())
  let completed = DispatchSemaphore(value: 0)

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let overflow = state.withLock { state in
      if state.failure != nil { return true }
      if data.count > 1_048_576 - state.body.count {
        state.failure = Failure("response body exceeds 1 MiB")
        return true
      }
      state.body.append(data)
      return false
    }
    if overflow { dataTask.cancel() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    var request = request
    // URLSession drops Authorization on every redirect; an API that redirects to its canonical path on the
    // same origin still needs it. A different scheme, host or port never gets it.
    if request.value(forHTTPHeaderField: "Authorization") == nil,
      let authorization = task.currentRequest?.value(forHTTPHeaderField: "Authorization"),
      let from = response.url, let to = request.url, sameOrigin(from, to)
    {
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    let allowed = state.withLock { state in
      guard let url = request.url, isHTTP(url) else {
        state.failure = Failure("redirect requires an HTTP(S) URL")
        return false
      }
      guard state.redirects < 5 else {
        state.failure = Failure("too many redirects")
        return false
      }
      state.redirects += 1
      return true
    }
    completionHandler(allowed ? request : nil)
  }

  private func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
    return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
      && port(a) == port(b)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    state.withLock { $0.failure = $0.failure ?? error }
    completed.signal()
  }

  func result(_ response: URLResponse?) throws -> [String: Any] {
    try state.withLock { state in
      if let failure = state.failure { throw failure }
      guard let response = response as? HTTPURLResponse else { throw Failure("expected an HTTP response") }
      var headers: [String: String] = [:]
      for (name, value) in response.allHeaderFields {
        headers[String(describing: name).lowercased()] = String(describing: value)
      }
      return [
        "status": response.statusCode, "headers": headers,
        "body": String(decoding: state.body, as: UTF8.self),
      ]
    }
  }
}
