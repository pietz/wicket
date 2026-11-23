import Darwin
import Foundation
import JavaScriptCore

struct Failure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

func withJSString<T>(_ text: String, _ body: (JSStringRef) throws -> T) rethrows -> T {
  let ref = Array(text.utf16).withUnsafeBufferPointer {
    JSStringCreateWithCharacters($0.baseAddress, $0.count)!
  }
  defer { JSStringRelease(ref) }
  return try body(ref)
}

func swiftString(_ ref: JSStringRef) -> String {
  String(
    decoding: UnsafeBufferPointer(start: JSStringGetCharactersPtr(ref), count: JSStringGetLength(ref)),
    as: UTF16.self)
}

private func textValue(_ context: JSContextRef, _ text: String) -> JSValueRef {
  withJSString(text) { JSValueMakeString(context, $0) }
}

func text(
  _ context: JSContextRef, _ value: JSValueRef, _ exception: UnsafeMutablePointer<JSValueRef?>? = nil
)
  -> String?
{
  guard let ref = JSValueToStringCopy(context, value, exception) else { return nil }
  defer { JSStringRelease(ref) }
  return swiftString(ref)
}

func property(
  _ context: JSContextRef, _ object: JSObjectRef, _ name: String,
  _ exception: UnsafeMutablePointer<JSValueRef?>? = nil
) -> JSValueRef? {
  withJSString(name) { JSObjectGetProperty(context, object, $0, exception) }
}

func reporting<T>(_ context: JSContextRef, _ perform: (inout JSValueRef?) -> T) throws -> T {
  var exception: JSValueRef?
  let result = perform(&exception)
  if let exception {
    let message = text(context, exception) ?? "JavaScript exception"
    if JSValueIsObject(context, exception), let line = property(context, exception, "line"),
      JSValueIsNumber(context, line),
      let lineNumber = text(context, line)
    {
      throw Failure("line \(lineNumber): \(message)")
    }
    throw Failure(message)
  }
  return result
}

private func install(
  _ context: JSContextRef, _ name: String, _ functions: [(String, JSObjectCallAsFunctionCallback)]
) {
  let object = JSObjectMake(context, nil, nil)!
  for (key, callback) in functions {
    withJSString(key) {
      let function = JSObjectMakeFunctionWithCallback(context, $0, callback)
      JSObjectSetProperty(context, object, $0, function, 0, nil)
    }
  }
  withJSString(name) { JSObjectSetProperty(context, JSContextGetGlobalObject(context), $0, object, 0, nil) }
}

private func log(
  _ context: JSContextRef?, _ function: JSObjectRef?, _ receiver: JSObjectRef?,
  _ count: Int, _ arguments: UnsafePointer<JSValueRef?>?, _ exception: UnsafeMutablePointer<JSValueRef?>?
) -> JSValueRef? {
  let context = context!
  var values: [String] = []
  for value in UnsafeBufferPointer(start: arguments, count: count) {
    guard let value, let message = text(context, value, exception) else { return nil }
    values.append(message)
  }
  FileHandle.standardError.write(Data((values.joined(separator: " ") + "\n").utf8))
  return JSValueMakeUndefined(context)
}

private func storage(
  _ context: JSContextRef, _ operation: String, _ count: Int,
  _ arguments: UnsafePointer<JSValueRef?>?, _ exception: UnsafeMutablePointer<JSValueRef?>?
) -> JSValueRef? {
  hostResult(context, operation, exception) {
    let writing = operation == "write"
    guard count == (writing ? 2 : 1), let arguments, let nameValue = arguments[0],
      JSValueIsString(context, nameValue), let name = text(context, nameValue)
    else { throw Failure(writing ? "expected a filename and text" : "expected a filename") }
    let file = try dataFile(name)
    if writing {
      guard let value = arguments[1], JSValueIsString(context, value), let contents = text(context, value)
      else { throw Failure("expected text") }
      try writeData(contents, to: file)
      return JSValueMakeUndefined(context)
    }
    return try readData(from: file).map { textValue(context, $0) } ?? JSValueMakeNull(context)
  }
}

func hostResult(
  _ context: JSContextRef, _ operation: String, _ exception: UnsafeMutablePointer<JSValueRef?>?,
  _ perform: () throws -> JSValueRef?
) -> JSValueRef? {
  do { return try perform() } catch {
    var message: JSValueRef? = textValue(context, "wicket.\(operation): \(error.localizedDescription)")
    exception?.pointee = JSObjectMakeError(context, 1, &message, nil)
    return nil
  }
}

private func scriptURL(_ path: String) throws -> URL {
  guard !path.isEmpty, path.utf8.first != UInt8(ascii: "/"), !path.utf8.contains(0),
    !path.components(separatedBy: "/").contains("..")
  else { throw Failure("expected a relative script path in the extension folder") }
  let directory = URL.currentDirectory().resolvingSymlinksInPath()
  let script = directory.appending(path: path).resolvingSymlinksInPath()
  guard script.pathComponents.starts(with: directory.pathComponents),
    script.pathComponents.count > directory.pathComponents.count
  else { throw Failure("script must be inside the extension folder") }
  return script
}

private func run(_ path: String) throws {
  _ = RequestBudget.deadline
  let context = JSGlobalContextCreate(nil)!
  defer { JSGlobalContextRelease(context) }
  guard let input = try FileHandle.standardInput.readToEnd(), let json = String(data: input, encoding: .utf8),
    let request = withJSString(json, { JSValueMakeFromJSONString(context, $0) }),
    JSValueIsObject(context, request), !JSValueIsArray(context, request)
  else { throw Failure("expected a UTF-8 JSON request object on stdin") }
  JSValueProtect(context, request)
  defer { JSValueUnprotect(context, request) }
  let rootMatch = property(context, request, "rootMatch").map { JSValueToBoolean(context, $0) } ?? false

  let promise = property(context, JSContextGetGlobalObject(context), "Promise")!
  JSValueProtect(context, promise)
  defer { JSValueUnprotect(context, promise) }
  install(context, "console", [("log", log), ("error", log)])
  install(
    context, "wicket",
    [
      ("read", { context, _, _, count, args, error in storage(context!, "read", count, args, error) }),
      ("write", { context, _, _, count, args, error in storage(context!, "write", count, args, error) }),
      ("fetch", rootMatch ? blockedFetch : fetchCallback),
      ("run", rootMatch ? blockedRun : runCallback),
    ])

  let script = try scriptURL(path)
  guard try script.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
  else { throw Failure("script must be a regular file") }
  let source = try String(contentsOf: script, encoding: .utf8)
  _ = try reporting(context) { exception in
    withJSString(source) { script in
      withJSString(path) { JSEvaluateScript(context, script, nil, $0, 1, &exception) }
    }
  }
  let main = try reporting(context) { exception in
    withJSString("typeof main === 'function' ? main : undefined") {
      JSEvaluateScript(context, $0, nil, nil, 1, &exception)
    }
  }
  guard let main, JSValueIsObject(context, main), JSObjectIsFunction(context, main) else {
    throw Failure("define a top-level main(request) function")
  }
  var argument: JSValueRef? = request
  guard
    let result = try reporting(context, { JSObjectCallAsFunction(context, main, nil, 1, &argument, &$0) })
  else { throw Failure("main returned no value") }
  JSValueProtect(context, result)
  defer { JSValueUnprotect(context, result) }
  if JSValueIsUndefined(context, result) { return }
  let output: String
  if JSValueIsString(context, result), let markdown = text(context, result) {
    output = markdown
  } else {
    guard JSValueIsObject(context, result) else {
      throw Failure("main must return a view object, a Markdown string, or undefined")
    }
    if try reporting(context, { JSValueIsInstanceOfConstructor(context, result, promise, &$0) }) {
      throw Failure("main must be synchronous; wicket.fetch returns directly")
    }
    guard !JSValueIsArray(context, result),
      let serialized = try reporting(context, { JSValueCreateJSONString(context, result, 0, &$0) })
    else { throw Failure("main must return an object that serializes as a JSON view") }
    defer { JSStringRelease(serialized) }
    output = swiftString(serialized)
    guard output.hasPrefix("{") else {
      throw Failure("main must return an object that serializes as a JSON view")
    }
  }
  try FileHandle.standardOutput.write(contentsOf: Data(output.utf8))
}

let arguments = CommandLine.arguments.dropFirst()
do {
  guard arguments.count == 1, let path = arguments.first else {
    throw Failure("expected one relative script path, for example: wicket-js main.js")
  }
  try run(path)
} catch {
  let source = arguments.count == 1 ? ": " + (arguments.first ?? "") : ""
  FileHandle.standardError.write(Data("wicket-js\(source): \(error.localizedDescription)\n".utf8))
  exit(1)
}
