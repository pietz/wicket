// ISO 4217 currency codes, including currencies Frankfurter may not quote.
let currencies = Set(
  """
  AED AFN ALL AMD AOA ARS AUD AWG AZN BAM BBD BDT BHD BIF BMD BND BOB BOV BRL BSD BTN BWP BYN BZD
  CAD CDF CHE CHF CHW CLF CLP CNY COP COU CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP
  GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR
  KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN
  MXV MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD
  SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX
  USD USN UYI UYU UYW UZS VED VES VND VUV WST XAD XAF XCD XCG XOF XPF YER ZAR ZMW ZWG
  """.split(whereSeparator: \.isWhitespace).map(String.init))

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
