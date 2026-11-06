import Testing

@testable import WicketCore

private let mail = RunningApp(processID: 42, bundleID: "com.apple.mail", name: "Mail")

@Test func pastesIntoARunningAppOnceTrusted() {
    #expect(
        PastePlan.decide(target: mail, isRunning: true, isTrusted: true, hasPrompted: false)
            == .paste(into: mail))
}

@Test func asksForAccessibilityOncePerSession() {
    #expect(
        PastePlan.decide(target: mail, isRunning: true, isTrusted: false, hasPrompted: false)
            == .copyOnly(.notTrusted(prompt: true)))
    #expect(
        PastePlan.decide(target: mail, isRunning: true, isTrusted: false, hasPrompted: true)
            == .copyOnly(.notTrusted(prompt: false)))
}

@Test func neverPromptsWhenThereIsNothingToPasteInto() {
    // Wicket was frontmost, or the app quit: Accessibility wouldn't have helped, so don't ask.
    #expect(
        PastePlan.decide(target: nil, isRunning: false, isTrusted: false, hasPrompted: false)
            == .copyOnly(.noTarget))
    #expect(
        PastePlan.decide(target: mail, isRunning: false, isTrusted: false, hasPrompted: false)
            == .copyOnly(.targetQuit(mail)))
}

@Test func fallbackMessagesNameTheApp() {
    #expect(PasteFallback.targetQuit(mail).message == "Copied: Mail has quit")
    #expect(PasteFallback.notFrontmost(mail).message == "Copied: couldn't switch to Mail")
    #expect(
        PasteFallback.targetQuit(RunningApp(processID: 1, bundleID: nil)).message
            == "Copied: the app has quit")
}

// Key codes (Carbon `kVK_*`): ANSI V is 9, K is 40, full stop is 47.
private let ansiV: UInt16 = 9

/// A layout that types `map`'s letters on its keys and nothing elsewhere.
private func layout(_ map: [UInt16: String]) -> (UInt16) -> String? { { map[$0] } }

@Test func findsVOnLatinLayouts() {
    // QWERTY, QWERTZ (German) and AZERTY all keep V on the ANSI key; Z, Y, A and Q move.
    let qwerty = layout([6: "z", 16: "y", 9: "v", 47: "."])
    let qwertz = layout([6: "y", 16: "z", 9: "v", 47: "."])
    let azerty = layout([0: "q", 12: "a", 9: "v", 47: ":"])
    for typing in [qwerty, qwertz, azerty] {
        #expect(KeyLookup.keyCode(typing: "v", preferring: ansiV, in: [typing]) == ansiV)
    }
}

@Test func findsVOnDvorak() {
    let dvorak = layout([9: "k", 47: "v", 40: "t"])
    #expect(KeyLookup.keyCode(typing: "v", preferring: ansiV, in: [dvorak]) == 47)
}

@Test func uppercaseTranslationsMatch() {
    #expect(KeyLookup.keyCode(typing: "v", preferring: ansiV, in: [layout([47: "V"])]) == 47)
}

@Test func fallsBackToTheASCIILayoutThenTheANSIKey() {
    // A layout with no Latin letters under ⌘ (the current one), then the ASCII-capable one.
    let cyrillic = layout([9: "м", 47: "ю"])
    let dvorak = layout([47: "v"])
    #expect(KeyLookup.keyCode(typing: "v", preferring: ansiV, in: [cyrillic, dvorak]) == 47)
    #expect(KeyLookup.keyCode(typing: "v", preferring: ansiV, in: [cyrillic]) == ansiV)
    #expect(KeyLookup.keyCode(typing: "v", preferring: ansiV, in: []) == ansiV)
}
