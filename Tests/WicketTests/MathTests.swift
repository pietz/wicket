import Foundation
import Testing

@testable import WicketApp

private let us = Locale(identifier: "en_US")
private let de = Locale(identifier: "de_DE")

@Test(arguments: [
  ("2+3*4", "14"), ("(2+3)*4", "20"), ("0.1+0.2", "0.3"), (".5 * 8", "4"),
  ("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"), ("2^-2", "0.25"),
  ("12 ÷ 3 × 2 − 1", "7"), ("1/3", "0.333333333333333"), ("1000*1000", "1,000,000"),
])
func arithmetic(input: String, expected: String) {
  #expect(Math.evaluate(input, locale: us)?.title == expected)
}

@Test(arguments: [
  ("200 + 10%", "220"), ("200 - 10%", "180"), ("10% of 200", "20"), ("50 * 10%", "5"), ("15%", "0.15"),
  ("200*10%", "20"), ("(20+30)%", "0.5"), ("200 + (10%)", "220"), ("10% + 5%", "0.15"),
  ("(100 + 10%) + 10%", "121"), ("200 + 10% * 2", "200.2"), ("100 / 10%", "1,000"),
])
func percentages(input: String, expected: String) {
  #expect(Math.evaluate(input, locale: us)?.title == expected)
}

@Test(arguments: [
  ("3,5 * 2", "7", "7"), ("1.234,5 + 0", "1234.5", "1234.5"), ("1,234.5 + 0", "1234.5", "1234.5"),
  ("1,000 + 1", "1001", "2"), ("1.000 + 1", "2", "1001"), ("1,000,000 / 2", "500000", "500000"),
  ("1.000.000 / 2", "500000", "500000"), ("0,500 * 2", "1", "1"), ("1,5 + 1.5", "3", "3"),
  ("10,5%", "0.105", "0.105"), ("1234,500 * 2", "2469", "2469"),
])
func decimalMarks(input: String, inUS: String, inGermany: String) {
  #expect(Math.evaluate(input, locale: us)?.copy == inUS)
  #expect(Math.evaluate(input, locale: de)?.copy == inGermany.replacingOccurrences(of: ".", with: ","))
}

@Test func resultsUseTheLocaleAndCopyAPlainNumber() {
  #expect(Math.evaluate("1234.5 * 2", locale: us) == .init(title: "2,469", copy: "2469"))
  #expect(Math.evaluate("1234,5 * 3", locale: de) == .init(title: "3.703,5", copy: "3703,5"))
  #expect(Math.evaluate("1 - 1", locale: de) == .init(title: "0", copy: "0"))
}

@Test(arguments: [
  "", "123", "hello", "2+", "(2+3", "2+3)", "2..3+1", "1/0", "0/0", "2^9999", "sqrt(4)", "2;3",
  "2**3", "2(3+4)", "10 usd", "1 2+3", "1,23,456 + 1", "1.2,3.4 + 1", "1, + 2", "1. + 2", "200 of 10%",
  "10% off 200", "1.234,5,6 * 2",
])
func invalidMath(input: String) {
  #expect(Math.evaluate(input, locale: us) == nil)
  #expect(Math.evaluate(input, locale: de) == nil)
}

@Test(arguments: [
  "2024-01-15", "555-1234", "-5", "+5", "−5", "-0", "11.11", "11.11.2026", "11/11/2026", "11-11-2026",
  "1.2.3", "1.2.3-beta", "192.168.1.1", "1,5", "-1,5",
  "+49 30 1234567", "555-123-4567", "(555) 123-4567", "+1 555-123-4567", "+1-555-123-4567",
])
func datesVersionsAndPhonesAreNotMath(input: String) {
  #expect(Math.evaluate(input, locale: us) == nil)
  #expect(Math.evaluate(input, locale: de) == nil)
}

@Test func boundedInput() {
  #expect(
    Math.evaluate(String(repeating: "(", count: 100) + "1+2" + String(repeating: ")", count: 100))
      == nil)
  #expect(Math.evaluate(String(repeating: "-", count: 100) + "2") == nil)
  #expect(Math.evaluate(String(repeating: "1+", count: 300) + "1") == nil)
}
