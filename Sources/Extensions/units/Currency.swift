// ISO 4217 List One (SIX, 2026-09-17), codes with a numeric minor unit.
func minorUnits() -> [String: Int] {
  let codes = [
    (
      0,
      """
      BIF CLP DJF GNF ISK JPY KMF KRW PYG RWF UGX UYI VND VUV XAF XOF XPF
      """
    ),
    (
      2,
      """
      AED AFN ALL AMD AOA ARS AUD AWG AZN BAM BBD BDT BMD BND BOB BOV BRL BSD BTN BWP BYN BZD CAD CDF
      CHE CHF CHW CNY COP COU CRC CUP CVE CZK DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD
      GTQ GYD HKD HNL HTG HUF IDR ILS INR IRR JMD KES KGS KHR KPW KYD KZT LAK LBP LKR LRD LSL MAD MDL
      MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD NGN NIO NOK NPR NZD PAB PEN PGK PHP PKR
      PLN QAR RON RSD RUB SAR SBD SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TOP
      TRY TTD TWD TZS UAH USD USN UYU UZS VED VES WST XAD XCD XCG YER ZAR ZMW ZWG
      """
    ),
    (
      3,
      """
      BHD IQD JOD KWD LYD OMR TND
      """
    ),
    (
      4,
      """
      CLF UYW
      """
    ),
  ]
  return Dictionary(
    uniqueKeysWithValues: codes.flatMap { places, codes in
      codes.split(whereSeparator: \.isWhitespace).map { (String($0), places) }
    })
}

func currencyCode(_ token: String, home: String) -> String {
  switch token {
  case "$":
    let dollars = """
      ARS AUD BBD BMD BND BSD BZD CAD CLP COP CUP DOP FJD GYD HKD JMD KYD LRD MXN NAD NZD SBD SGD SRD TTD
      TWD USD UYU XCD
      """
    return dollars.split(whereSeparator: \.isWhitespace).contains(Substring(home)) ? home : "USD"
  case "¥": return home == "CNY" ? home : "JPY"
  case "€": return "EUR"
  case "£": return "GBP"
  default: return token.uppercased()
  }
}

func isCurrencySymbol(_ character: Character) -> Bool {
  "€$£¥".contains(character)
}
