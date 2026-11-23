import Darwin
import Foundation
import JavaScriptCore

enum RequestBudget {
  static let deadline: UInt64 = {
    if let value = getenv("WICKET_JS_DEADLINE_NS"), let deadline = UInt64(String(cString: value)) {
      return deadline
    }
    return DispatchTime.now().uptimeNanoseconds + 10_000_000_000
  }()

  static func limit(_ milliseconds: Double) throws -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadline else { throw Failure("request timed out") }
    return now + UInt64(min(milliseconds * 1_000_000, Double(deadline - now)))
  }
}

let blockedFetch: JSObjectCallAsFunctionCallback = { context, _, _, _, _, error in
  hostResult(context!, "fetch", error) { throw Failure("unavailable during a root match") }
}

let blockedRun: JSObjectCallAsFunctionCallback = { context, _, _, _, _, error in
  hostResult(context!, "run", error) { throw Failure("unavailable during a root match") }
}

let fetchCallback: JSObjectCallAsFunctionCallback = { context, _, _, count, args, error in
  let context = context!
  return hostResult(context, "fetch", error) {
    let call = try HostCall(context, count, args)
    guard let url = try httpURL(call.string(call.first, named: "url")) else {
      throw Failure("expected an HTTP(S) URL")
    }
    let method = try call.stringOption("method") ?? "GET"
    guard isHTTPToken(method) else { throw Failure("invalid HTTP method") }
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let headers = try call.option("headers") {
      let names = JSObjectCopyPropertyNames(context, try call.object(headers, named: "headers"))!
      defer { JSPropertyNameArrayRelease(names) }
      for index in 0..<JSPropertyNameArrayGetCount(names) {
        let name = JSPropertyNameArrayGetNameAtIndex(names, index)!
        let key = swiftString(name)
        let value = try reporting(context) { JSObjectGetProperty(context, headers, name, &$0) }
        let header = try call.string(value, named: "header value")
        guard isHTTPToken(key), !header.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else {
          throw Failure("invalid HTTP header")
        }
        request.setValue(header, forHTTPHeaderField: key)
      }
    }
    request.httpBody = try call.stringOption("body").map { Data($0.utf8) }
    let deadline = try RequestBudget.limit(call.limit("timeoutMs", default: 5_000))
    return try call.result(fetch(request, deadline: deadline))
  }
}

let runCallback: JSObjectCallAsFunctionCallback = { context, _, _, count, args, error in
  let context = context!
  return hostResult(context, "run", error) {
    let call = try HostCall(context, count, args)
    guard JSValueIsArray(context, call.first),
      let size = try reporting(context, { property(context, call.first, "length", &$0) }),
      JSValueIsNumber(context, size),
      let length = UInt32(exactly: JSValueToNumber(context, size, nil)), length > 0
    else { throw Failure("expected a nonempty argv array") }
    var argv: [String] = []
    for index in 0..<length {
      let value = try reporting(context) { JSObjectGetPropertyAtIndex(context, call.first, index, &$0) }
      let argument = try call.string(value, named: "argv element")
      guard !argument.utf8.contains(0) else { throw Failure("argv cannot contain NUL") }
      argv.append(argument)
    }
    let input = try call.stringOption("input").map { Data($0.utf8) } ?? Data()
    let bytes = try Int(call.limit("maxBytes", default: 262_144, maximum: 1_048_576))
    let deadline = try RequestBudget.limit(call.limit("timeoutMs", default: 2_000, maximum: 5_000))
    return try call.result(runCommand(argv, input: input, maxBytes: bytes, deadline: deadline))
  }
}

private func isHTTPToken(_ string: String) -> Bool {
  !string.isEmpty
    && string.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || "!#$%&'*+-.^`_|~".utf8.contains($0)
    }
}

private struct HostCall {
  let context: JSContextRef
  let first: JSValueRef
  let options: JSValueRef?

  init(_ context: JSContextRef, _ count: Int, _ arguments: UnsafePointer<JSValueRef?>?) throws {
    guard (1...2).contains(count), let arguments, let first = arguments[0]
    else { throw Failure("expected one argument and optional options") }
    self.context = context
    self.first = first
    options = count == 2 ? arguments[1] : nil
    if let options, !JSValueIsUndefined(context, options) {
      _ = try object(options, named: "options")
    }
  }

  func object(_ value: JSValueRef, named name: String) throws -> JSObjectRef {
    guard JSValueIsObject(context, value), !JSValueIsArray(context, value),
      !JSObjectIsFunction(context, value)
    else { throw Failure("expected an object for \(name)") }
    return value
  }

  func option(_ name: String) throws -> JSValueRef? {
    guard let options, !JSValueIsUndefined(context, options),
      let value = try reporting(context, { property(context, options, name, &$0) }),
      !JSValueIsUndefined(context, value)
    else { return nil }
    return value
  }

  func string(_ value: JSValueRef?, named name: String) throws -> String {
    guard let value, JSValueIsString(context, value), let string = text(context, value)
    else { throw Failure("expected a string for \(name)") }
    return string
  }

  func stringOption(_ name: String) throws -> String? {
    try option(name).map { try string($0, named: name) }
  }

  func limit(_ name: String, default fallback: Double, maximum: Double = .infinity) throws -> Double {
    guard let value = try option(name) else { return fallback }
    let number = JSValueIsNumber(context, value) ? JSValueToNumber(context, value, nil) : .nan
    guard number.isFinite, number > 0, number.rounded(.down) == number, number <= maximum else {
      throw Failure("invalid \(name)")
    }
    return number
  }

  func result(_ values: [String: Any]) throws -> JSValueRef? {
    let json = try JSONSerialization.data(withJSONObject: values)
    return withJSString(String(decoding: json, as: UTF8.self)) { JSValueMakeFromJSONString(context, $0) }
  }
}
