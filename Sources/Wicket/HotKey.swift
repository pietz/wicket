import Carbon.HIToolbox

/// Global hotkeys through Carbon's `RegisterEventHotKey`: still the only public API for a system-wide
/// shortcut that needs no Accessibility or Input Monitoring permission.
@MainActor
final class HotKey {
    /// The handler receives the key event's timestamp (seconds since boot, same clock as
    /// `ProcessInfo.systemUptime`), so latency can be measured from the keypress itself.
    typealias Handler = @MainActor (_ eventTime: TimeInterval) -> Void

    private static var handlers: [UInt32: Handler] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `keyCode` is a Carbon virtual key code (`kVK_*`), `modifiers` Carbon flags (`optionKey`, ...).
    init?(keyCode: Int, modifiers: Int, handler: @escaping Handler) {
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5743_4B54), id: id)  // 'WCKT'
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                let time = GetEventTime(event)
                // Carbon dispatches application-target events on the main thread.
                MainActor.assumeIsolated { HotKey.handlers[hotKeyID.id]?(time) }
                return noErr
            }, 1, &spec, nil, nil)
    }
}
