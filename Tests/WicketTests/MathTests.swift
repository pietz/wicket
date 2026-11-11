import Testing

@testable import WicketApp

@Test(arguments: [
  ("2+3*4", "14"), ("(2+3)*4", "20"), ("0.1+0.2", "0.3"), (".5 * 8", "4"),
  ("200*10%", "20"), ("100+10%", "100.1"), ("50%", "0.5"), ("(20+30)%", "0.5"),
  ("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"), ("2^-2", "0.25"),
  ("12 ÷ 3 × 2 − 1", "7"), ("1/3", "0.333333333333333"),
])
func arithmetic(input: String, expected: String) { #expect(Math.evaluate(input) == expected) }

@Test(arguments: [
  "", "123", "hello", "2+", "(2+3", "2+3)", "2..3+1", "1/0", "0/0", "2^9999", "sqrt(4)", "2;3",
  "2**3", "2(3+4)", "10 usd", "1 2+3",
])
func invalidMath(input: String) { #expect(Math.evaluate(input) == nil) }

@Test func boundedInput() {
  #expect(
    Math.evaluate(String(repeating: "(", count: 100) + "1+2" + String(repeating: ")", count: 100))
      == nil)
  #expect(Math.evaluate(String(repeating: "-", count: 100) + "2") == nil)
  #expect(Math.evaluate(String(repeating: "1+", count: 300) + "1") == nil)
}
